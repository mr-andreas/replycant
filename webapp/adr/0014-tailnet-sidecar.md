# ADR-0014: Bundled tsnet Sidecar For Desktop Tailnet Membership

## Status
Accepted

## Context
[server ADR-0010](https://github.com/mr-andreas/replycant/blob/main/server/adr/0010-headscale-tailnet-transport.md)
moved gitd behind a self-hosted tailnet and removed its published ports. The
desktop app therefore has to become a tailnet node before it can reach git, LFS,
decryptd, or transcoded at all.

Tailscale's userspace networking is a Go library. Node has no equivalent, and
the alternatives were worse:

- Requiring the user to install the Tailscale client means a second install
  step, an admin prompt, a `NET_ADMIN`-equivalent system extension, and a
  tailnet shared with whatever else they use Tailscale for.
- Reimplementing WireGuard and the Tailscale control protocol in TypeScript is
  not a serious option.

The desktop app has never shipped a native binary, so this also decides how one
gets built and packaged.

## Decision
Ship a Go sidecar that runs `tsnet` in userspace and exposes it to the existing
Node networking stack as a SOCKS5 proxy.

- `webapp/sidecar/` is a Go program in the root module. It runs `tsnet`, exposes
  the built-in SOCKS5 proxy via `tsnet.Server.Loopback()`, and runs the
  headscale loopback shim that adds pinned TLS and the device certificate to
  control-plane traffic.
- Configuration is passed on stdin, not argv. The pre-auth key and private key
  material would otherwise be visible in the process table.
- The sidecar prints its loopback proxy address on stdout and the main process
  waits for it, so nothing races the bind.
- `webapp/electron/tailnetSupervisor.ts` owns the process lifecycle. Starts are
  serialised so an overlapping join cannot leave two nodes running, and a
  restart stops the previous node first.
- `webapp/electron/registerTailnetIpc.ts` exposes `tailnet:join`,
  `tailnet:leave`, and `tailnet:status`. The renderer is a trust boundary, so
  join requests are parsed and validated there rather than forwarded.
- The proxy is composed into the existing mTLS agent pool from
  [ADR-0013](0013-pooled-mtls-upstream-agents.md) as a `socks-proxy-agent`
  under the `https.Agent`, so pooling and the session-scoped material from
  [ADR-0011](0011-session-scoped-mtls-material.md) are untouched and mTLS stays
  end to end.
- `electron-builder` carries the binary through `extraResources`, built by
  `webapp/scripts/buildSidecar.mjs` with `CGO_ENABLED=0`. The release workflow
  gains a Go toolchain on every desktop runner.
- Tailnet configuration is persisted so the app rejoins on unlock and at
  startup rather than asking the user to pair again.

## Consequences

### Positive
- The desktop app joins the tailnet without the user installing anything, and
  without a privileged network extension.
- The tailnet is private to Replycant. It does not touch a user's own Tailscale
  account or tailnet.
- mTLS, CA pinning, and agent pooling are unchanged: SOCKS only changes how the
  TCP connection is obtained.
- Traffic that should not be proxied is unaffected, because the proxy is applied
  at the agent rather than process-wide.

### Negative
- The desktop app now ships a platform-specific native binary. Release builds
  need a Go toolchain, and the artifact list grows per platform and
  architecture.
- Another process to supervise, with its own crash and restart semantics.
- The tailnet is only up while the desktop app runs.
- Configuration on stdin keeps secrets out of the process table but means the
  sidecar cannot be started by hand for debugging without reproducing that
  handshake.
