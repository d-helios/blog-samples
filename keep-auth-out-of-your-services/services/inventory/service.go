package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync"

	"connectrpc.com/connect"

	inventoryv1 "github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/inventory/v1"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/internal/rpc"
)

type stock struct {
	available int32
	reserved  int32
	committed int32
}

type reservation struct {
	sku       string
	quantity  int32
	committed bool
}

type inventory struct {
	log *slog.Logger

	mu           sync.Mutex
	stock        map[string]*stock
	reservations map[string]*reservation
}

func newInventory(log *slog.Logger, initial map[string]int32) *inventory {
	s := make(map[string]*stock, len(initial))
	for sku, qty := range initial {
		s[sku] = &stock{available: qty}
	}
	return &inventory{log: log, stock: s, reservations: map[string]*reservation{}}
}

func (i *inventory) GetStock(
	_ context.Context, req *connect.Request[inventoryv1.GetStockRequest],
) (*connect.Response[inventoryv1.GetStockResponse], error) {
	i.mu.Lock()
	defer i.mu.Unlock()

	s, ok := i.stock[req.Msg.GetSku()]
	if !ok {
		return nil, connect.NewError(connect.CodeNotFound, fmt.Errorf("unknown sku %q", req.Msg.GetSku()))
	}
	return connect.NewResponse(&inventoryv1.GetStockResponse{Stock: toProto(req.Msg.GetSku(), s)}), nil
}

func (i *inventory) Reserve(
	_ context.Context, req *connect.Request[inventoryv1.ReserveRequest],
) (*connect.Response[inventoryv1.ReserveResponse], error) {
	m := req.Msg
	if m.GetOrderId() == "" || m.GetQuantity() <= 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("order_id and a positive quantity are required"))
	}

	i.mu.Lock()
	defer i.mu.Unlock()

	s, ok := i.stock[m.GetSku()]
	if !ok {
		return nil, connect.NewError(connect.CodeNotFound, fmt.Errorf("unknown sku %q", m.GetSku()))
	}
	if _, exists := i.reservations[m.GetOrderId()]; exists {
		return nil, connect.NewError(connect.CodeAlreadyExists, fmt.Errorf("order %s already has a reservation", m.GetOrderId()))
	}
	if s.available < m.GetQuantity() {
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			fmt.Errorf("not enough %s: %d available, %d requested", m.GetSku(), s.available, m.GetQuantity()))
	}

	s.available -= m.GetQuantity()
	s.reserved += m.GetQuantity()
	i.reservations[m.GetOrderId()] = &reservation{sku: m.GetSku(), quantity: m.GetQuantity()}

	i.log.Info("stock reserved", "order_id", m.GetOrderId(), "sku", m.GetSku(), "quantity", m.GetQuantity(),
		"by", req.Header().Get(rpc.SubjectHeader))
	return connect.NewResponse(&inventoryv1.ReserveResponse{Stock: toProto(m.GetSku(), s)}), nil
}

func (i *inventory) Commit(
	_ context.Context, req *connect.Request[inventoryv1.CommitRequest],
) (*connect.Response[inventoryv1.CommitResponse], error) {
	i.mu.Lock()
	defer i.mu.Unlock()

	r, ok := i.reservations[req.Msg.GetOrderId()]
	if !ok {
		return nil, connect.NewError(connect.CodeNotFound, fmt.Errorf("no reservation for order %s", req.Msg.GetOrderId()))
	}
	if r.committed {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("reservation for order %s is already committed", req.Msg.GetOrderId()))
	}

	s := i.stock[r.sku]
	s.reserved -= r.quantity
	s.committed += r.quantity
	r.committed = true

	i.log.Info("reservation committed", "order_id", req.Msg.GetOrderId(), "sku", r.sku, "quantity", r.quantity,
		"by", req.Header().Get(rpc.SubjectHeader))
	return connect.NewResponse(&inventoryv1.CommitResponse{Stock: toProto(r.sku, s)}), nil
}

// Recalculate rebuilds reserved/committed counters from the reservation log.
func (i *inventory) Recalculate(
	_ context.Context, _ *connect.Request[inventoryv1.RecalculateRequest],
) (*connect.Response[inventoryv1.RecalculateResponse], error) {
	i.mu.Lock()
	defer i.mu.Unlock()

	for _, s := range i.stock {
		s.available += s.reserved + s.committed
		s.reserved, s.committed = 0, 0
	}
	for _, r := range i.reservations {
		s := i.stock[r.sku]
		s.available -= r.quantity
		if r.committed {
			s.committed += r.quantity
		} else {
			s.reserved += r.quantity
		}
	}

	skus := make([]string, 0, len(i.stock))
	for sku := range i.stock {
		skus = append(skus, sku)
	}
	sort.Strings(skus)

	res := &inventoryv1.RecalculateResponse{}
	for _, sku := range skus {
		res.Stock = append(res.Stock, toProto(sku, i.stock[sku]))
	}
	i.log.Debug("stock recalculated", "skus", len(skus), "reservations", len(i.reservations))
	return connect.NewResponse(res), nil
}

func toProto(sku string, s *stock) *inventoryv1.Stock {
	return &inventoryv1.Stock{Sku: sku, Available: s.available, Reserved: s.reserved, Committed: s.committed}
}
