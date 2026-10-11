package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/mr-andreas/replycant/pkg/tailnetagent"
)

const remoteHelperName = "git-remote-replycant"
const remoteHelperPrefix = "replycant::"

// ensureTailnetAgent is replaced in tests so the helper can be checked
// without joining a tailnet.
var ensureTailnetAgent = tailnetagent.Ensure

// execRemoteHTTPS is replaced in tests. Production runs git's own https
// helper with the tailnet proxy injected through the environment.
var execRemoteHTTPS = runGitRemoteHTTPS

// isRemoteHelper reports whether this process was started as git's remote
// helper. Git selects the helper from argv[0], so the same binary serves
// both the CLI and the transport.
func isRemoteHelper(argv0 string) bool {
	return filepath.Base(argv0) == remoteHelperName
}

// runRemoteHelper connects git's https transport to the repository's tailnet
// node. gitd has no host address, so a plain https remote cannot reach it.
func runRemoteHelper(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: git-remote-replycant <remote> <url>")
	}
	gitDir, err := helperGitDir()
	if err != nil {
		return err
	}
	cfg, err := tailnetagent.LoadStartConfig(gitDir)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	proxyURL, err := ensureTailnetAgent(ctx, gitDir, cfg, nil)
	if err != nil {
		return err
	}
	return execRemoteHTTPS(withHTTPProxy(os.Environ(), proxyURL), stripHelperPrefix(args)...)
}

// stripHelperPrefix removes the replycant:: marker git keeps on the remote
// name when the URL was passed directly rather than through a named remote.
func stripHelperPrefix(args []string) []string {
	out := make([]string, len(args))
	for i, arg := range args {
		out[i] = strings.TrimPrefix(arg, remoteHelperPrefix)
	}
	return out
}

// withHTTPProxy adds the agent address without putting it on the command
// line. The proxy URL contains the credential that authorizes local dials.
func withHTTPProxy(env []string, proxyURL string) []string {
	count := 0
	kept := make([]string, 0, len(env)+3)
	for _, entry := range env {
		if strings.HasPrefix(entry, "GIT_CONFIG_COUNT=") {
			parsed, err := strconv.Atoi(strings.TrimPrefix(entry, "GIT_CONFIG_COUNT="))
			if err == nil && parsed > count {
				count = parsed
			}
			continue
		}
		kept = append(kept, entry)
	}
	return append(kept,
		fmt.Sprintf("GIT_CONFIG_COUNT=%d", count+1),
		fmt.Sprintf("GIT_CONFIG_KEY_%d=http.proxy", count),
		fmt.Sprintf("GIT_CONFIG_VALUE_%d=%s", count, proxyURL),
	)
}

// helperGitDir finds the repository git invoked the helper for.
//
// GIT_DIR is set by git and may be relative to the work tree. Later agent
// state is stored under it, so a relative path would follow whatever cwd a
// later command happened to have.
func helperGitDir() (string, error) {
	dir := strings.TrimSpace(os.Getenv("GIT_DIR"))
	if dir == "" {
		out, err := exec.Command("git", "rev-parse", "--absolute-git-dir").Output()
		if err != nil {
			return "", fmt.Errorf("resolve git dir: %w", err)
		}
		dir = strings.TrimSpace(string(out))
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("resolve git dir: %w", err)
	}
	return abs, nil
}

// runTailnetAgent is the process the helper detaches. Configuration is read
// from stdin so the device private key is not visible in the process list.
func runTailnetAgent() error {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read tailnet agent configuration: %w", err)
	}
	cfg, err := tailnetagent.DecodeStartConfig(raw)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return tailnetagent.Run(ctx, cfg)
}

func runGitRemoteHTTPS(env []string, args ...string) error {
	cmd := exec.Command("git", append([]string{"remote-https"}, args...)...)
	cmd.Env = env
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
