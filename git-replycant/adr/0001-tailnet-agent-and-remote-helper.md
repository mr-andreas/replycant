# ADR-0001: Per-Repository Tailnet Agent And Git Remote Helper

## Status

Accepted

## Context

gitd listens only at `https://gitd.replycant.internal:8443`, inside the
deployment tailnet. The CLI used to discover a LAN URL from caserver and
dial it directly. That path is gone: there is no host port, and a
`.local` name no longer reaches the server.

Several processes need the network at once. `git fetch` and `git push`
run in one process, the pre-push hook uploads LFS in another, and
`git-lfs filter-process` smudges in a third. Each of them cannot start
its own tsnet node against the same state directory. They have to share
one node per repository.

The desktop app already solves the control-plane problem with a
loopback shim in front of hsproxy. The CLI needs the same shim, plus a
way for unmodified git and git-lfs to dial through the node.

## Decision

The tailnet is the only path `git-replycant` supports.

- `git-replycant clone` takes no server URL. It shows a loopback pairing
  QR, polls the discovery host until a paired device publishes a sealed
  record, joins the tailnet, and only then fetches.
- Origin is `replycant::https://gitd.replycant.internal:8443`. The
  `git-remote-replycant` name is this same binary. It ensures the agent
  is running and execs `git remote-https` with `http.proxy` set through
  the environment, so the proxy credential is not on the command line.
- `git-replycant tailnet-agent` is a hidden subcommand. One instance per
  repository holds a lock under `.git/replycant/tailnet/`, joins with
  tsnet, and serves an authenticated HTTP CONNECT proxy on
  `127.0.0.1`. mTLS to gitd stays end to end. The agent exits after
  about five minutes with no proxied connections, and removes its
  readiness file on the way out.
- The pre-auth key is passed on the agent's stdin and is not stored.
  `tailnet/config.json` is written only after the node is up.
- LFS smudge, the pre-push hook, and `replycant-importer` use that same
  proxy. A repository without tailnet config fails with a re-clone
  error. There is no direct dial and no mDNS fallback.

## Consequences

- An existing CLI clone cannot be upgraded in place. The user clones
  again and approves the new QR.
- Releases must ship `git-remote-replycant` as a symlink to
  `git-replycant`. Clone checks for it before pairing.
- The agent is a long-lived process only while git or LFS is active.
  Two overlapping commands share it; a second agent exits because the
  lock is held.
- Joining still depends on Tailscale's public DERP map for the first
  control session. After the node is up, control prefers gitd's
  in-tailnet relay and falls back to hsproxy.
