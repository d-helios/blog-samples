package main

import (
	"net/http"
	"os"

	"connectrpc.com/connect"

	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/gen/inventory/v1/inventoryv1connect"
	"github.com/d-helios/blog-samples/keep-auth-out-of-your-services/internal/rpc"
)

func main() {
	log := rpc.NewLogger("inventory")

	svc := newInventory(log, map[string]int32{
		"widget": 1000,
		"gadget": 500,
	})

	mux := http.NewServeMux()
	mux.Handle(inventoryv1connect.NewInventoryServiceHandler(svc,
		connect.WithInterceptors(rpc.Logging(log)),
	))

	if err := rpc.Serve(log, rpc.Env("ADDR", ":8080"), mux); err != nil {
		log.Error("server stopped", "error", err)
		os.Exit(1)
	}
}
