package main

import (
	"fmt"
	"os"

	"github.com/alecthomas/kong"
)

// main dispatches subcommands so git can invoke clone and filter operations from one binary.
func main() {
	if err := runCLI(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// CLI defines the git-replycant command tree so parsing stays declarative and consistent.
type CLI struct {
	Clone         CloneCommand         `cmd:"" help:"Clone and configure a replycant repository."`
	FilterProcess FilterProcessCommand `cmd:"" name:"filter-process" help:"Run the long-lived Git clean/smudge process filter."`
	PrePush       PrePushCommand       `cmd:"" name:"pre-push" help:"Upload LFS objects for Replycant pointers before push."`
	Smudge        SmudgeCommand        `cmd:"" help:"Smudge a manifest from stdin or a file path."`
	Clean         CleanCommand         `cmd:"" help:"Clean a manifest from stdin or a file path."`
}

// CloneCommand models clone flags and args while keeping the runtime logic in clone.go.
type CloneCommand struct {
	DeviceName string `name:"device-name" help:"Optional device name override."`
	Depth      int    `name:"depth" help:"Shallow clone depth (0 for full history)." default:"0"`
	Bare       bool   `name:"bare" help:"Create a bare repository."`
	NoLFS      bool   `name:"no-lfs" help:"Skip LFS setup even when the server provides an LFS URL."`
	ServerURL  string `arg:"" name:"server-url" required:"" help:"Replycant caserver URL (for example http://host:8080)."`
	Directory  string `arg:"" optional:"" name:"directory" help:"Optional clone destination directory."`
}

// FilterProcessCommand models the process subcommand used by Git filter.process integration.
type FilterProcessCommand struct{}

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
		DeviceName: c.DeviceName,
		Depth:      c.Depth,
		Bare:       c.Bare,
		NoLFS:      c.NoLFS,
		ServerURL:  c.ServerURL,
		Directory:  c.Directory,
	})
}

// Run executes the Git filter process command.
func (c *FilterProcessCommand) Run() error {
	return RunFilterProcess()
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
