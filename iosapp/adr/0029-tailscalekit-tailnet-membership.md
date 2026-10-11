# ADR-0029: In-Process TailscaleKit For Tailnet Membership

## Status
Accepted

## Context
[server ADR-0010](https://github.com/mr-andreas/replycant/blob/main/server/adr/0010-headscale-tailnet-transport.md)
removed gitd's published ports. The app can no longer reach the server over the
LAN or a forwarded port; it has to be a node on the deployment's tailnet.

iOS offers two shapes for that. A `NEPacketTunnelProvider` network extension
gives system-wide routing, but it needs the Network Extension entitlement, a
second binary, its own memory budget, and a VPN profile the user must approve —
and it would capture traffic Replycant has no business capturing. Userspace
networking inside the app process routes only what the app asks it to.

Two things about the client libraries forced further decisions.
`TailscaleKit`/`tsnet` accepts a control URL but offers no way to install a
private trust root or a client certificate for it, and this deployment's control
plane sits behind an mTLS front door signed by a CA that exists only on the
user's own server. And `libtailscale` has no tags or releases, so there is no
version to depend on.

## Decision
Run Tailscale in userspace inside the app process and route the app's own
`URLSession` traffic through it.

- Vendor `TailscaleKit` by building the `ios-fat` xcframework from a pinned
  `libtailscale` commit (`TAILSCALEKIT_REV` in the root `Makefile`) into a
  gitignored path, rather than committing the artifact. The framework is
  approximately 70 MB and this repository's history is public and permanent.
  Every `ios-*` make target depends on the build.
- `LibGit2Package` and `GitDBPackage` raise their iOS floor to 18.0, following
  the framework's 18.1 minimum. The app already targets 18.5.
- `HeadscaleControlShim` binds an `NWListener` on loopback and relays each
  accepted connection to `hsproxy` over an `NWConnection` whose
  `sec_protocol` verify block trusts only the onboarded CA and which presents
  the existing `SecIdentity`. `Configuration.controlURL` points at that
  listener. Bytes are relayed opaquely, because the control protocol upgrades a
  `POST` into a long-lived stream.
- Trust evaluation replaces the system anchors rather than adding to them
  (`SecTrustSetAnchorCertificatesOnly`). The control-plane hostname is a
  subdomain of a shared tunnel domain, so a publicly trusted certificate for
  that name must not be accepted.
- Evaluate under `SecPolicyCreateBasicX509`, not `SecPolicyCreateSSL`. The SSL
  policy enforces Apple's 398-day maximum certificate lifetime even against a
  programmatically pinned anchor, and the compose stack issues ten-year leaves
  so an unattended self-hosted server never breaks on an expiry nobody is
  watching. This matches how `MTLSTransport` already pins gitd.
- `TailnetManager` owns the shim and node lifecycle. `TailnetSessionRouter` is a
  singleton that applies the node's SOCKS proxy to a
  `URLSessionConfiguration`, and every call site that talks to gitd goes through
  it: `MTLSTransport`, `GitLFS`, `HLSResourceLoader`, and
  `DirectPlayResourceLoader`.
- The router exposes a synchronous variant alongside the async one, because
  libgit2's transport callbacks are C functions with no place to await.
- The app declares required-reason API usage in `PrivacyInfo.xcprivacy`: file
  timestamp, disk space, system boot time, and `UserDefaults`. The framework
  ships no manifest and the Go runtime's `stat`, `statfs`, and `sysctl` calls
  would otherwise take ITMS-91053 at submission.
- Work around two upstream sharp edges: `TailscaleNode.down()` calls
  `tailscale_up`, so shutdown uses `close()`; and `proxyVia()` takes an actor
  hop that deadlocks against a blocking `up()`.

## Consequences

### Positive
- No Network Extension entitlement, no VPN profile prompt, and no system-wide
  traffic capture. Only requests the app routes go over the tailnet.
- The tailnet identity is the existing device `SecIdentity`, so revoking a
  device in `pubkeys/` closes tailnet access and Git access together.
- Applying the proxy in one router rather than at each call site means a new
  `URLSession` cannot silently bypass the tailnet by forgetting a parameter.
- Pinning a commit makes the dependency reproducible despite upstream having no
  releases.

### Negative
- Building the app now requires a Go toolchain and a first-time xcframework
  build of several minutes. CI cannot rely on a checked-in binary.
- The iOS deployment floor rises to 18.0 for the local packages.
- The tailnet is only up while the app is running, so anything expecting
  background reachability has to tolerate the node being down.
- The plaintext loopback hop between the Tailscale client and the shim exists
  because the client will not accept a private trust root. It never leaves the
  device, and the control protocol is Noise-encrypted end to end regardless,
  but it is a hop that would not exist if the library took a `SecTrust`
  callback.
- `PrivacyInfo.xcprivacy` now covers reasons that come from a vendored Go
  runtime rather than from app code, so it has to be re-checked whenever
  `TAILSCALEKIT_REV` moves.
- The control-plane certificate's hostname is not checked, because iOS exposes
  no way to read subject alternative names and the SSL policy that would do it
  rejects the deployment's certificate lifetimes. The deployment CA signs only
  the two server certificates on the user's own host and device identities are
  self-signed, so a wrong-hostname certificate from that CA already implies a
  compromised host — but this is a weaker check than the Go clients perform.
