# ADR-0006: Route LFS Through gitd mTLS Proxy

## Status
Superseded by [ADR-0009](0009-native-lfs-server-in-gitd.md)

## Context
Replycant currently uses `lfs-test-server` with static Basic credentials
(`admin:admin`). Git traffic already passes through gitd with mTLS and
`pubkeys/` authorization, but LFS traffic can bypass that trust boundary when
clients connect directly to the LFS service.

We need one authenticated entrypoint for both Git and LFS now, while keeping
the current LFS backend until a native gitd LFS implementation exists.

## Decision
Expose Git LFS through gitd at `https://{host}:8443/lfs`.

- gitd authenticates requests with the same mTLS + `pubkeys/` flow used for Git
  Smart HTTP.
- After authentication, gitd reverse-proxies `/lfs/*` requests to the configured
  upstream `--lfs-url`.
- gitd injects upstream Basic auth derived from `--lfs-url` userinfo so clients
  do not need to send `admin:admin`.
- gitd rewrites LFS batch action `href` values to `https://{host}:8443/lfs/...`
  so follow-up upload/download/verify requests stay on the authenticated route.
- CA server QR and `/config.json` advertise only `{ca, url}`. Clients derive
  the public LFS endpoint as `{origin(url)}/lfs`.

The `--lfs-url` flag remains the internal upstream endpoint and still backs
`REPLYCANT_LFS_URL` for pre-receive object existence checks.

## Consequences

### Positive
- External LFS access is protected by the same mTLS identity model as Git.
- Clients no longer depend on embedded Basic credentials for normal LFS flows.
- Existing LFS backend remains usable with minimal operational change.

### Negative
- gitd now owns HTTP proxy behavior (streaming, header forwarding, response rewrite).
- Batch-response rewriting adds a protocol-coupled surface that must stay aligned
  with LFS API behavior.
- Internal services still use Basic auth against upstream LFS until they are
  migrated or replaced.
