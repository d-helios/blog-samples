package main

import (
	"net/http"
	"os"
	"time"

	"connectrpc.com/connect"

	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/inventory/v1/inventoryv1connect"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/orders/v1/ordersv1connect"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/internal/rpc"
)

func main() {
	log := rpc.NewLogger("orders")
	logging := connect.WithInterceptors(rpc.Logging(log))

	inventory := inventoryv1connect.NewInventoryServiceClient(
		&http.Client{Timeout: 5 * time.Second},
		rpc.Env("INVENTORY_URL", "http://inventory"),
		logging,
	)

	mux := http.NewServeMux()
	mux.Handle(ordersv1connect.NewOrdersServiceHandler(newOrders(log, inventory), logging))

	if err := rpc.Serve(log, rpc.Env("ADDR", ":8080"), mux); err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
}
