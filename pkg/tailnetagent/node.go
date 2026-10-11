package tailnetagent

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"

	"github.com/mr-andreas/replycant/pkg/tailnetnode"
)

// Run joins the tailnet described by cfg and serves the repository proxy
// until the process is asked to stop or the proxy goes idle.
func Run(ctx context.Context, cfg StartConfig) error {
	if _, err := encodeStartConfig(cfg); err != nil {
		return err
	}
	clientCert, err := tls.X509KeyPair([]byte(cfg.ClientCertPEM), []byte(cfg.ClientKeyPEM))
	if err != nil {
		return fmt.Errorf("the device certificate and key do not form a usable pair: %w", err)
	}

	logger := log.New(os.Stderr, "tailnet-agent: ", 0)
	device, err := tailnetnode.StartDevice(ctx, tailnetnode.DeviceConfig{
		HeadscaleAddr:       cfg.HeadscaleAddr,
		HeadscaleServerName: cfg.HeadscaleServerName,
		CAPEM:               []byte(cfg.CAPEM),
		ClientCertificate:   clientCert,
		Dir:                 statePath(Dir(cfg.GitDir)),
		Hostname:            cfg.Hostname,
		Logf:                logger.Printf,
	})
	if err != nil {
		return err
	}
	defer device.Close()

	server := &Server{Dir: Dir(cfg.GitDir), Dial: device.Node.Dial}
	return server.Run(ctx)
}
