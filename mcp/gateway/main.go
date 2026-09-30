package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	configPath := flag.String("config", "", "path to the gateway configuration JSON")
	flag.Parse()
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "ai-sandbox-mcp-gateway requires --config")
		os.Exit(2)
	}
	cfg, err := loadGatewayConfig(*configPath)
	if err != nil {
		log.Fatalf("gateway config: %v", err)
	}

	listener, err := net.Listen("tcp", cfg.Bind)
	if err != nil {
		log.Fatalf("gateway listen on %s: %v", cfg.Bind, err)
	}

	server := &http.Server{
		Handler:           newGatewayServer(cfg),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       5 * time.Minute,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("gateway shutdown: %v", err)
		}
	}()

	log.Printf("ai-sandbox mcp gateway listening on %s", listener.Addr())
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("gateway serve: %v", err)
	}
}
