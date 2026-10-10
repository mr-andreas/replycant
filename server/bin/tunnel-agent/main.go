// Command tunnel-agent keeps the home deployment reachable from the internet
// without the user forwarding a router port.
//
// It dials the hosted relay and holds that connection open, so arriving device
// connections are pushed back down it. Run alongside hsproxy.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/tunnelagent"
)

// Mirrors gitd's and hsproxy's flag style so all three services are configured
// the same way.
type CLI struct {
	RelayAddr    string `required:"" help:"Relay registration endpoint as host:port (e.g. tunnel.replycant.com:8444)"`
	UpstreamAddr string `default:"hsproxy:8443" help:"Local hsproxy address that relayed connections are spliced to"`

	Cert string `required:"" help:"Path to the hsproxy TLS certificate; presented to the relay to prove which CA this deployment belongs to" type:"path"`
	Key  string `required:"" help:"Path to the hsproxy TLS private key" type:"path"`
	CA   string `required:"" help:"Path to the deployment CA certificate; the relay derives the tunnel subdomain from it" type:"path"`

	RelayCA         string `help:"Optional path to a certificate pinning a self-hosted relay; defaults to the hosted relay's certificate built into this binary" type:"path"`
	RelayServerName string `help:"Overrides the SNI presented to the relay; defaults to the relay hostname"`

	MinBackoff time.Duration `default:"1s" help:"Initial delay before retrying a failed registration"`
	MaxBackoff time.Duration `default:"2m" help:"Longest delay between registration attempts"`
}

func main() {
	var cli CLI
	ctx := kong.Parse(&cli,
		kong.Name("tunnel-agent"),
		kong.Description("Maintains the outbound reverse tunnel that publishes headscale through the hosted relay"),
		kong.UsageOnError(),
	)

	log.Printf("Loaded CLI configuration: %+v", cli)

	var relayCAPEM []byte
	if cli.RelayCA != "" {
		var err error
		relayCAPEM, err = os.ReadFile(cli.RelayCA)
		ctx.FatalIfErrorf(err)
	}

	agent, err := tunnelagent.New(tunnelagent.Config{
		RelayAddr:       cli.RelayAddr,
		UpstreamAddr:    cli.UpstreamAddr,
		CertPath:        cli.Cert,
		KeyPath:         cli.Key,
		CAPath:          cli.CA,
		RelayCAPEM:      relayCAPEM,
		RelayServerName: cli.RelayServerName,
		MinBackoff:      cli.MinBackoff,
		MaxBackoff:      cli.MaxBackoff,
	})
	ctx.FatalIfErrorf(err)

	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Run only returns once the context is cancelled; every other failure is
	// retried internally, because a home connection dropping is routine.
	if err := agent.Run(signalCtx); err != nil && signalCtx.Err() == nil {
		log.Fatalf("tunnel-agent stopped: %v", err)
	}
	log.Println("Shutdown complete")
}
