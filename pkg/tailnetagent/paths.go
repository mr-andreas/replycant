// Package tailnetagent keeps one userspace tailnet node per repository and
// exposes it as a loopback CONNECT proxy.
//
// git, git-lfs, and the pre-push hook are separate processes, and they are
// alive at the same time during a push. They cannot each start tsnet against
// the same node state, so they share the agent started here instead.
package tailnetagent

import (
	"path/filepath"
)

const (
	configFileName   = "config.json"
	readyFileName    = "agent.json"
	lockFileName     = "agent.lock"
	spawnLockName    = "spawn.lock"
	logFileName      = "agent.log"
	stateDirName     = "tsnet"
	proxyUsername    = "replycant"
	replycantDirName = "replycant"
)

// Dir is where a repository keeps its tailnet node, proxy address, and join
// coordinates. It lives under the git dir so bare repos and worktrees share
// one node with the repository they actually authenticate as.
func Dir(gitDir string) string {
	return filepath.Join(gitDir, replycantDirName, "tailnet")
}

func readyPath(dir string) string {
	return filepath.Join(dir, readyFileName)
}

func lockPath(dir string) string {
	return filepath.Join(dir, lockFileName)
}

func spawnLockPath(dir string) string {
	return filepath.Join(dir, spawnLockName)
}

func logPath(dir string) string {
	return filepath.Join(dir, logFileName)
}

func configPath(dir string) string {
	return filepath.Join(dir, configFileName)
}

func statePath(dir string) string {
	return filepath.Join(dir, stateDirName)
}
