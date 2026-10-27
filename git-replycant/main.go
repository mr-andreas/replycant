package main

import (
	"fmt"
	"os"

	"github.com/alecthomas/kong"
)

// main dispatches subcommands so git can invoke clone, filter, and the
// tailnet transport from one binary.
func main() {
	if err := dispatch(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// dispatch sends git's remote-helper invocation to the tailnet transport
// before kong sees it. Git picks the helper by argv[0], which is not a
// subcommand it would know to pass through. A one-argument tailnet-agent
// re-exec is the exception: that child is the agent, not another helper.
func dispatch() error {
	if useRemoteHelper(os.Args) {
		return runRemoteHelper(os.Args[1:])
	}
	return runCLI()
}

// CLI defines the git-replycant command tree so parsing stays declarative and consistent.
type CLI struct {
	Clone         CloneCommand         `cmd:"" help:"Clone and configure a replycant repository."`
	FilterProcess FilterProcessCommand `cmd:"" name:"filter-process" help:"Run the long-lived Git clean/smudge process filter."`
	TailnetAgent  TailnetAgentCommand  `cmd:"" name:"tailnet-agent" hidden:"" help:"Run the per-repository tailnet node. Started by git, not by users."`
	PrePush       PrePushCommand       `cmd:"" name:"pre-push" help:"Upload LFS objects for Replycant pointers before push."`
	Smudge        SmudgeCommand        `cmd:"" help:"Smudge a manifest from stdin or a file path."`
	Clean         CleanCommand         `cmd:"" help:"Clean a manifest from stdin or a file path."`
}

// CloneCommand models clone flags and args while keeping the runtime logic in clone.go.
//
// There is no server URL. gitd is reached only after this machine pairs into
// the deployment tailnet, and every client already knows its MagicDNS name.
type CloneCommand struct {
	DeviceName   string `name:"device-name" help:"Optional device name override."`
	Depth        int    `name:"depth" help:"Shallow clone depth (0 for full history)." default:"0"`
	Bare         bool   `name:"bare" help:"Create a bare repository."`
	NoLFS        bool   `name:"no-lfs" help:"Skip LFS setup."`
	DiscoveryURL string `name:"discovery-url" default:"https://discovery.replycant.com" help:"Discovery API base URL. The pairing slot is prepended as a subdomain."`
	QRAddr       string `name:"qr-addr" default:"127.0.0.1:0" help:"Loopback address for the pairing QR page."`
	Directory    string `arg:"" optional:"" name:"directory" help:"Clone destination directory. Defaults to replycant."`
}

// FilterProcessCommand models the process subcommand used by Git filter.process integration.
type FilterProcessCommand struct{}

// TailnetAgentCommand is the background node shared by fetch, push, and LFS.
//
// It is hidden because users never run it: the remote helper and the filters
// start it, and its configuration arrives on stdin so the device key stays
// out of the process list.
type TailnetAgentCommand struct{}

// PrePushCommand models git hook invocation to upload missing LFS objects before ref updates.
type PrePushCommand struct {
	RemoteName string `arg:"" name:"remote-name" required:"" help:"Remote name passed by git pre-push."`
	RemoteURL  string `arg:"" name:"remote-url" required:"" help:"Remote URL passed by git pre-push."`
}

// SmudgeCommand models optional path input for textconv compatibility.
type SmudgeCommand struct {
	File string `arg:"" optional:"" name:"file" help:"Optional file path; when omitted reads from stdin."`
}

// CleanCommand models optional path input for textconv compatibility.
type CleanCommand struct {
	File string `arg:"" optional:"" name:"file" help:"Optional file path; when omitted reads from stdin."`
}

// Run executes clone with normalized options validated in clone.go.
func (c *CloneCommand) Run() error {
	return RunCloneCommand(CloneOptions{
		DeviceName:   c.DeviceName,
		Depth:        c.Depth,
		Bare:         c.Bare,
		NoLFS:        c.NoLFS,
		DiscoveryURL: c.DiscoveryURL,
		QRAddr:       c.QRAddr,
		Directory:    c.Directory,
	})
}

// Run executes the Git filter process command.
func (c *FilterProcessCommand) Run() error {
	return RunFilterProcess()
}

// Run joins the tailnet and serves the loopback proxy until the node is idle.
func (c *TailnetAgentCommand) Run() error {
	return runTailnetAgent()
}

// Run uploads missing LFS objects referenced by newly pushed Replycant pointers.
func (c *PrePushCommand) Run() error {
	return RunPrePush(c.RemoteName, c.RemoteURL, os.Stdin)
}

// Run executes one-shot smudge with optional file-path argument support.
func (c *SmudgeCommand) Run() error {
	args := []string{}
	if c.File != "" {
		args = append(args, c.File)
	}
	return RunSmudgeOnce(args)
}

// Run executes one-shot clean with optional file-path argument support.
func (c *CleanCommand) Run() error {
	args := []string{}
	if c.File != "" {
		args = append(args, c.File)
	}
	return RunCleanOnce(args)
}

// runCLI parses and dispatches CLI commands through kong for consistent arg validation and help text.
func runCLI() error {
	var cli CLI
	parser, err := kong.New(
		&cli,
		kong.Name("git-replycant"),
		kong.Description("Helper CLI for cloning and filtering replycant repositories."),
		kong.UsageOnError(),
	)
	if err != nil {
		return err
	}
	ctx, err := parser.Parse(os.Args[1:])
	if err != nil {
		return err
	}
	return ctx.Run()
}
