package main

import (
	"context"
	"net/http"

	"github.com/mr-andreas/replycant/pkg/tailnetagent"
)

// ensureRepoProxy returns the loopback proxy for this repository, starting
// the shared agent when it is not already running.
//
// Every network path — git, git-lfs, and the pre-push upload — has to dial
// through that one node. A missing configuration is a clone that predates
// the tailnet and has to be created again.
func ensureRepoProxy(repoRoot string) (string, error) {
	gitDir, err := resolveGitDir(repoRoot)
	if err != nil {
		return "", err
	}
	cfg, err := tailnetagent.LoadStartConfig(gitDir)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), tailnetagent.DefaultReadyTimeout)
	defer cancel()
	return tailnetagent.Ensure(ctx, gitDir, cfg, nil)
}

// tailnetHTTPClient is the mTLS client for LFS uploads. The proxy is not
// optional: gitd is not listening on the host network.
func tailnetHTTPClient(repoRoot, caPath, certPath, keyPath string) (*http.Client, error) {
	proxyURL, err := ensureRepoProxy(repoRoot)
	if err != nil {
		return nil, err
	}
	return tailnetagent.HTTPClient(caPath, certPath, keyPath, proxyURL)
}

// lfsProxyEnv is what git-lfs reads when it dials. The credential stays in
// the environment of the child process rather than in git config, because
// the proxy port changes each time the agent starts.
func lfsProxyEnv(proxyURL string) []string {
	return []string{
		"http_proxy=" + proxyURL,
		"https_proxy=" + proxyURL,
		"HTTP_PROXY=" + proxyURL,
		"HTTPS_PROXY=" + proxyURL,
	}
}
