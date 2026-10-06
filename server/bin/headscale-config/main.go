// Command headscale-config writes headscale's config.yaml and policy.json.
//
// headscale's image is distroless and cannot template its own config, and the
// policy has to name the same tags and ports gitd and hsproxy use. Rendering
// both from server/tailnet keeps one source for those values in production
// and in the integration harness.
package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/alecthomas/kong"
	"github.com/mr-andreas/replycant/server/tailnet"
)

type CLI struct {
	ServerURL  string `required:"" help:"URL headscale advertises to nodes (the tunnel hostname, or your own DNS name in manual mode)"`
	ListenAddr string `default:"0.0.0.0:8080" help:"Address headscale listens on"`
	OutDir     string `required:"" help:"Directory to write config.yaml and policy.json into" type:"path"`
}

func main() {
	var cli CLI
	ctx := kong.Parse(&cli,
		kong.Name("headscale-config"),
		kong.Description("Writes headscale's config and policy for a replycant deployment"),
		kong.UsageOnError(),
	)

	config, err := tailnet.RenderHeadscaleConfig(tailnet.HeadscaleConfigSettings{
		ServerURL:  cli.ServerURL,
		ListenAddr: cli.ListenAddr,
	})
	ctx.FatalIfErrorf(err)
	policy, err := tailnet.RenderHeadscalePolicy()
	ctx.FatalIfErrorf(err)

	ctx.FatalIfErrorf(os.MkdirAll(cli.OutDir, 0o755))
	ctx.FatalIfErrorf(writeAtomically(filepath.Join(cli.OutDir, "config.yaml"), config))
	ctx.FatalIfErrorf(writeAtomically(filepath.Join(cli.OutDir, "policy.json"), policy))
	log.Printf("Wrote headscale config for %s and the device-isolating policy to %s", cli.ServerURL, cli.OutDir)
}

// headscale reads both files at start; a half-written file left by a crash
// would keep it from starting until the next render.
func writeAtomically(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("replace %s: %w", path, err)
	}
	return nil
}
