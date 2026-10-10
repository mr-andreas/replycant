# ADR-0010: Headscale Tailnet Transport For All Client Traffic

## Status
Accepted. Where tailnet keys come from, hsproxy's pure splicing, and init-time
key capture are superseded by
[ADR-0011](0011-headscale-state-derived-from-git.md). Retaining the `.local`
SAN for LAN-only deployments is superseded: LAN-only mode was removed, and
the integration harness runs on the tailnet like a real deployment. The
double-sealed pairing record, the CA-label check, and manual-exposure
delivery are superseded by
[ADR-0013](0013-pairing-record-authenticated-only.md).

## Context
gitd published its mTLS Git port and its CA port on the host. Reaching a home
server from outside the LAN therefore required the user to forward a router
port, run dynamic DNS, and accept a permanently internet-exposed TLS listener.
That is a setup step most users cannot complete, and for those who can it is
attack surface that exists whether or not anyone is syncing.

Moving clients onto a private network solves reachability without exposing
anything, but a self-hosted tailnet has its own bootstrap problem: the control
plane has to be reachable from the internet for a device to join, and a device
that has never paired holds no trust anchor with which to verify what it finds
there.

Three constraints shaped the design:

- headscale generates pre-auth key material server-side and stores only a hash
  ([`hscontrol/db/preauth_keys.go`](https://github.com/juanfont/headscale/blob/v0.29.3/hscontrol/db/preauth_keys.go)),
  so a client cannot propose a key it already knows.
- headscale has no `ClientCAs` or `RequireAndVerifyClientCert` support and no
  configuration for a private CA, so it cannot authenticate devices itself.
- A pure TCP relay cannot inspect client certificates, because TLS 1.3 encrypts
  the Certificate message.

## Decision
All client-to-gitd traffic moves onto a self-hosted tailnet, with headscale
colocated with gitd and reached through an authenticating front door.

- Add `headscale` to compose on a plain-HTTP listener bound to the compose
  network only. `base_domain: replycant.internal`, `derp.server.enabled: false`,
  `derp.urls` pointing at Tailscale's public DERP map.
- Add `hsproxy` (`server/hsproxy`, `server/bin/hsproxy`): terminates TLS with a
  CA-issued certificate, sets `ClientAuth: RequireAnyClientCert`, and authorizes
  the presented public key with the existing
  [`server/gitd/auth`](../gitd/auth/auth.go) `Authenticator` against `pubkeys/`.
  It raw-splices bytes rather than proxying HTTP, because the Tailscale control
  protocol upgrades a `POST` into a long-lived bidirectional stream.
- Embed `tsnet` in gitd behind `--tsnet-dir`, `--tsnet-control-url`,
  `--tsnet-hostname`, `--tsnet-auth-key-file`, and serve the mTLS listener on
  `tsnet.Listen`. Remove gitd's `ports:` block entirely.
- `server-key` derives the deployment's public hostname from the CA:
  `{sha256(ca.der)[:32]}.s{NN}.tunnel.replycant.com`. The shard slot is a
  byte of the same digest just past the label, modulo a permanently fixed
  64. Growing the relay fleet therefore repoints DNS for some slots and
  never moves a deployment, so no hsproxy certificate is reissued and no
  stored `headscale_url` goes stale. The certificate is issued for that
  hostname and also carries `DNS:gitd.replycant.internal`, because after
  the first control session a device reaches hsproxy through gitd's
  in-tailnet TCP splice rather than through the hosted relay.
- gitd listens a second time on its existing tsnet node (`:8444`) and
  raw-splices accepted connections to hsproxy. Device shims prefer that
  MagicDNS address once the node is `Running`, and fall back to the
  relay hostname when it is not. A device cannot route to peers before
  it is up, so the first control session of every app launch still
  crosses the relay; what changes is that the relay stops holding a
  stream for the whole session.
- gitd mints a per-pairing pre-auth key over headscale's HTTP API and returns it
  inside a record sealed twice: encrypted to the pairing device's age key, then
  wrapped in an AEAD under a key derived from a secret that only ever appears in
  the pairing QR code. Encryption to the device key alone would give
  confidentiality but no writer authentication, because device public keys are
  published in `pubkeys/` and the discovery slot travels in the clear as a
  hostname. The outer wrap is what stops a planted record from enrolling a
  device into someone else's tailnet.
- `hsproxy` is the only service with a `ports:` entry, bound to `127.0.0.1` by
  default. Manual-exposure deployments set `REPLYCANT_HSPROXY_BIND=0.0.0.0` and
  `REPLYCANT_HEADSCALE_URL`, and skip the hosted relay and discovery API.

`trusted_proxies` is left empty on purpose: `hsproxy` splices raw TCP and adds
no `X-Forwarded-For`, so trusting a proxy there would only let clients spoof
their own logged source address.

## Consequences

### Positive
- No router configuration and no publicly exposed gitd listener.
- Tailnet access and Git access share one credential and one revocation
  mechanism: deleting a `.pub` file closes both.
- Devices reach gitd by a stable MagicDNS name instead of a per-network address,
  so the client no longer needs to be reconfigured when the network changes.
- The `.local` SAN is retained, so LAN-only deployments and the integration
  harness keep working without a tailnet. *(Superseded: LAN-only mode and the
  `.local` SAN were removed.)*

### Negative
- Two more services in compose (`headscale`, `hsproxy`) plus two init jobs
  (`headscale-config`, `headscale-init`), and a named volume to share
  headscale's CLI unix socket.
- No plain-LAN URL to gitd exists any more. Every device joins the tailnet
  first, including devices sitting next to the server.
- Peer traffic that cannot connect directly relays through Tailscale's public
  DERP mesh. It stays WireGuard-encrypted, but the fallback depends on
  infrastructure Replycant does not run.
- `headscale-init` runs the `-debug` image because the default image is
  distroless. Its busybox shell lives at `/busybox/sh`, which is an
  image-layout detail the compose file now depends on.
- Pre-auth keys and the headscale API key are only shown at creation, so they
  are captured at init time and written to disk under the data directory.
