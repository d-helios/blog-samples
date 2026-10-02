package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	inventoryv1 "github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/inventory/v1"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/inventory/v1/inventoryv1connect"
	ordersv1 "github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/orders/v1"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/internal/rpc"
)

type orders struct {
	log       *slog.Logger
	inventory inventoryv1connect.InventoryServiceClient

	mu     sync.Mutex
	orders map[string]*ordersv1.Order
}

func newOrders(log *slog.Logger, inventory inventoryv1connect.InventoryServiceClient) *orders {
	return &orders{log: log, inventory: inventory, orders: map[string]*ordersv1.Order{}}
}

func (o *orders) GetOrder(
	_ context.Context, req *connect.Request[ordersv1.GetOrderRequest],
) (*connect.Response[ordersv1.GetOrderResponse], error) {
	order, err := o.find(req.Msg.GetId())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&ordersv1.GetOrderResponse{Order: order}), nil
}

func (o *orders) CreateOrder(
	ctx context.Context, req *connect.Request[ordersv1.CreateOrderRequest],
) (*connect.Response[ordersv1.CreateOrderResponse], error) {
	if req.Msg.GetSku() == "" || req.Msg.GetQuantity() <= 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("sku and a positive quantity are required"))
	}

	order := &ordersv1.Order{
		Id:       newID(),
		Sku:      req.Msg.GetSku(),
		Quantity: req.Msg.GetQuantity(),
		State:    ordersv1.OrderState_ORDER_STATE_DRAFT,
	}

	reserve := connect.NewRequest(&inventoryv1.ReserveRequest{
		OrderId:  order.Id,
		Sku:      order.Sku,
		Quantity: order.Quantity,
	})
	forward(req.Header(), reserve.Header(), "Authorization", rpc.RequestIDHeader)
	if _, err := o.inventory.Reserve(ctx, reserve); err != nil {
		return nil, err
	}

	// Recalculate is a service-to-service call: orders sends no user token and
	// is authorized by its own mesh identity.
	recalc := connect.NewRequest(&inventoryv1.RecalculateRequest{})
	forward(req.Header(), recalc.Header(), rpc.RequestIDHeader)
	if _, err := o.inventory.Recalculate(ctx, recalc); err != nil {
		return nil, err
	}

	o.mu.Lock()
	o.orders[order.Id] = order
	o.mu.Unlock()

	o.log.Info("order created", "order_id", order.Id, "sku", order.Sku, "quantity", order.Quantity,
		"by", req.Header().Get(rpc.SubjectHeader))
	return connect.NewResponse(&ordersv1.CreateOrderResponse{Order: clone(order)}), nil
}

func (o *orders) SubmitOrder(
	ctx context.Context, req *connect.Request[ordersv1.SubmitOrderRequest],
) (*connect.Response[ordersv1.SubmitOrderResponse], error) {
	order, err := o.find(req.Msg.GetId())
	if err != nil {
		return nil, err
	}
	if order.State != ordersv1.OrderState_ORDER_STATE_DRAFT {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("order %s is %s, not DRAFT", order.Id, order.State))
	}

	commit := connect.NewRequest(&inventoryv1.CommitRequest{OrderId: order.Id})
	forward(req.Header(), commit.Header(), "Authorization", rpc.RequestIDHeader)
	if _, err := o.inventory.Commit(ctx, commit); err != nil {
		return nil, err
	}

	o.mu.Lock()
	stored := o.orders[order.Id]
	stored.State = ordersv1.OrderState_ORDER_STATE_SUBMITTED
	order = clone(stored)
	o.mu.Unlock()

	o.log.Info("order submitted", "order_id", order.Id, "by", req.Header().Get(rpc.SubjectHeader))
	return connect.NewResponse(&ordersv1.SubmitOrderResponse{Order: order}), nil
}

func (o *orders) find(id string) (*ordersv1.Order, error) {
	o.mu.Lock()
	defer o.mu.Unlock()

	order, ok := o.orders[id]
	if !ok {
		return nil, connect.NewError(connect.CodeNotFound, fmt.Errorf("order %q not found", id))
	}
	return clone(order), nil
}

func clone(o *ordersv1.Order) *ordersv1.Order {
	return proto.CloneOf(o)
}

func forward(from, to http.Header, keys ...string) {
	for _, k := range keys {
		if v := from.Get(k); v != "" {
			to.Set(k, v)
		}
	}
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
