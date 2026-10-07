package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/decred/dcrd/chaincfg/v3"
	"github.com/decred/dcrd/dcrutil/v4"
	"github.com/jzbz/map.dcr.pw/crawler"
	"github.com/jzbz/map.dcr.pw/server"
)

var (
	homeDir = dcrutil.AppDataDir("dcrmapper", false)
)

func run(ctx context.Context) error {

	// Parse CLI args.
	testnet := flag.Bool("testnet", false, "run on testnet")
	var listen, domain, proxy, onionSeed string
	flag.StringVar(&listen, "listen", "127.0.0.1:8111", "listen address:port")
	flag.StringVar(&domain, "domain", "localhost", "cookie domain")
	flag.StringVar(&proxy, "proxy", "", "SOCKS5 proxy (e.g. arti/tor at 127.0.0.1:9150) for reaching onion peers")
	flag.StringVar(&onionSeed, "onion-seed", "", "comma-separated v3 .onion bootstrap addresses (requires -proxy)")
	flag.Parse()

	params := chaincfg.MainNetParams()
	if *testnet {
		params = chaincfg.TestNet3Params()
	}

	var onionSeeds []string
	if onionSeed != "" {
		onionSeeds = strings.Split(onionSeed, ",")
	}

	mgr, err := crawler.New(homeDir, params, seedIPs, proxy, onionSeeds)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize crawler: %v\n", err)
		return err
	}

	// Waitgroup for services to signal when they have shutdown cleanly.
	var wg sync.WaitGroup

	mgr.Start(ctx, &wg)

	// Start HTTP server
	err = server.Start(ctx, listen, domain, mgr, shutdownRequestChannel, &wg, templatesFS, publicFS())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize server: %v\n", err)
		requestShutdown()
		wg.Wait()
		// Return the actual failure rather than the context error so the
		// process exits non-zero.
		return err
	}

	// Wait for shutdown tasks to complete before running deferred tasks and
	// returning.
	wg.Wait()

	return ctx.Err()
}

func main() {
	// Create a context that is cancelled when a shutdown request is received
	// through an interrupt signal.
	ctx := withShutdownCancel(context.Background())
	go shutdownListener()

	// Run until error is returned, or shutdown is requested.
	if err := run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		os.Exit(1)
	}
}
