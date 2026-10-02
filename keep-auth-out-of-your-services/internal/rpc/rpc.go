// Package rpc holds the plumbing shared by the Go services: logging, the
// Connect logging interceptor and an HTTP server with graceful shutdown.
package rpc

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"connectrpc.com/connect"
)

const (
	RequestIDHeader = "X-Request-Id"
	// SubjectHeader is set by the authorization layer in front of the service.
	// Services log it; they never make decisions on it.
	SubjectHeader = "X-Auth-Subject"
)

func NewLogger(service string) *slog.Logger {
	level := slog.LevelInfo
	if v := os.Getenv("LOG_LEVEL"); v != "" {
		if err := level.UnmarshalText([]byte(v)); err != nil {
			level = slog.LevelInfo
		}
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	return slog.New(h).With("service", service)
}

// Logging logs every unary call. It works on both handlers and clients, so the
// same interceptor shows what a service received and what it sent downstream.
func Logging(log *slog.Logger) connect.UnaryInterceptorFunc {
	return func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			start := time.Now()
			res, err := next(ctx, req)

			kind := "server"
			if req.Spec().IsClient {
				kind = "client"
			}
			attrs := []any{
				"kind", kind,
				"procedure", req.Spec().Procedure,
				"request_id", req.Header().Get(RequestIDHeader),
				"duration_ms", time.Since(start).Milliseconds(),
			}
			if kind == "server" {
				attrs = append(attrs, "subject", req.Header().Get(SubjectHeader))
			}

			if err == nil {
				log.InfoContext(ctx, "rpc", append(attrs, "code", "ok")...)
				return res, nil
			}
			code := connect.CodeOf(err)
			attrs = append(attrs, "code", code.String(), "error", err.Error())
			if isServerFault(code) {
				log.ErrorContext(ctx, "rpc", attrs...)
			} else {
				log.WarnContext(ctx, "rpc", attrs...)
			}
			return res, err
		}
	}
}

func isServerFault(code connect.Code) bool {
	switch code {
	case connect.CodeInternal, connect.CodeUnknown, connect.CodeUnavailable,
		connect.CodeDataLoss, connect.CodeDeadlineExceeded, connect.CodeUnimplemented:
		return true
	}
	return false
}

// Serve runs the handler until SIGINT/SIGTERM and then drains in-flight requests.
func Serve(log *slog.Logger, addr string, mux *http.ServeMux) error {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errCh; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func Env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
