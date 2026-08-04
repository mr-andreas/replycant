# Server Architecture

gitd is a Go-based Git server that provides authenticated access to repositories using mTLS with P-256 ECDSA certificates. It wraps `git-http-backend` for Git protocol handling and also acts as the single authenticated entrypoint for every backend service, exposing them as reverse-proxy routes.

## Overview

gitd runs two HTTP servers:

| Server | Port | Protocol | Purpose |
|--------|------|----------|---------|
| Git Server | 8443 | HTTPS (mTLS) | Git Smart HTTP + service proxy routes |
| CA Server | 8080 | HTTP | Certificate distribution for device onboarding |

These are the only ports published to the host. The backend services sit on an
internal Docker network and are reachable only through gitd:

| Route | Upstream service | Purpose |
|-------|------------------|---------|
| `/lfs` | lfs (`:8083`) | Git LFS object storage |
| `/decryptd` | decryptd (`:8084`) | On-the-fly decryption of LFS objects |
| `/transcoded` | transcoded (`:8082`) | HLS transcoding for video playback |

```mermaid
flowchart LR
  webapp[webapp proxy]
  iosapp[iosapp]
  gitd["gitd :8443 mTLS"]
  lfs["lfs :8083"]
  decryptd["decryptd :8084"]
  transcoded["transcoded :8082"]

  webapp --> gitd
  iosapp --> gitd
  gitd -->|"/lfs"| lfs
  gitd -->|"/decryptd"| decryptd
  gitd -->|"/transcoded"| transcoded
  decryptd --> lfs
  transcoded --> decryptd
```

Because decryptd and transcoded serve plaintext media derived from the encrypted
library and perform no authentication of their own, putting them behind gitd is
what keeps decrypted photos and video unreachable without a device certificate.
See [ADR-0007](https://github.com/mr-andreas/replycant/blob/main/server/adr/0007-gitd-media-service-proxy.md).

```
┌─────────────────────────────────────────────────────────┐
│                         gitd                            │
├─────────────────────────┬───────────────────────────────┤
│     Git Server (:8443)  │      CA Server (:8080)        │
│                         │                               │
│  ┌──────────────────┐   │   ┌───────────────────────┐   │
│  │  TLS 1.3 + mTLS  │   │   │  QR Code Generation   │   │
│  └────────┬─────────┘   │   └───────────────────────┘   │
│           │             │                               │
│  ┌────────▼─────────┐   │   ┌───────────────────────┐   │
│  │  Authentication  │   │   │  Certificate Display  │   │
│  └────────┬─────────┘   │   └───────────────────────┘   │
│           │             │                               │
│  ┌────────▼─────────┐   │                               │
│  │ git-http-backend │   │                               │
│  └──────────────────┘   │                               │
└─────────────────────────┴───────────────────────────────┘
```

## Git Server

The Git server handles all Git Smart HTTP operations with mTLS authentication.

### Requirements

- **TLS 1.3**: Minimum TLS version enforced for all connections
- **Client Certificate**: Every request must include a valid P-256 ECDSA certificate
- **Bare Repository**: The target repository must be a bare Git repository

### Request Flow

1. Client initiates TLS connection with client certificate
2. Server extracts P-256 public key from certificate
3. Server validates key against authorized keys in `pubkeys/` directory
4. If authorized and the path matches a service route (`/lfs/*`, `/decryptd/*`, `/transcoded/*`), the prefix is stripped and the request is proxied to that upstream, with server-side Basic auth injected when the configured upstream URL carries credentials
5. Otherwise, request is proxied to `git-http-backend` via CGI
6. On push (`git-receive-pack`), Git runs the `pre-receive` hook to verify referenced LFS objects exist
7. If validation succeeds, refs are updated; otherwise the push is rejected atomically

### CGI Environment

The server passes these environment variables to `git-http-backend`:

| Variable | Description |
|----------|-------------|
| `GIT_PROJECT_ROOT` | Path to the bare repository |
| `GIT_HTTP_EXPORT_ALL` | Set to `1` to allow access without `git-daemon-export-ok` |
| `REMOTE_USER` | Authenticated username (from pubkey filename) |
| `REPLYCANT_LFS_URL` | LFS server URL used by the pre-receive validator |

## CA Certificate Distribution

The CA server provides a simple way for devices to obtain the server's CA certificate and connection details.

### Endpoints

| Endpoint | Content-Type | Description |
|----------|--------------|-------------|
| `/` | `text/html` | HTML page with QR code and copyable text |
| `/qr.png` | `image/png` | QR code image for scanning |
| `/config.json` | `application/json` | Machine-readable config payload for browser discovery |

### QR Code Data

The QR code contains JSON with all information needed to configure a client:

```json
{
  "url": "https://hostname:8443/",
  "ca": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
}
```

| Field | Description |
|-------|-------------|
| `url` | Git server URL (mTLS endpoint) |
| `ca` | PEM-encoded CA certificate for server validation |

Clients derive every service endpoint as `{origin(url)}/{service}` (for example
`https://hostname:8443/lfs` or `https://hostname:8443/decryptd`), so discovery
never carries per-service fields and adding a service needs no protocol change.

The `/config.json` endpoint returns the same `{ca, url}` payload as the QR JSON
and includes `Access-Control-Allow-Origin: *` so browser onboarding flows can
discover configuration programmatically.

### Device Onboarding

1. Open CA server URL in browser (e.g., `http://server:8080`)
2. Scan QR code with mobile app, or copy values manually
3. App extracts CA certificate and server URLs from QR data
4. App configures certificate pinning and server endpoints

## Key Caching

Authorized keys from the `pubkeys/` directory are cached to minimize repository reads.

### Cache Behavior

- **Default TTL**: 5 minutes (configurable via `--cache-ttl` flag)
- **Cache invalidation**: Expired entries are reloaded from repository
- **Retry on failure**: If authentication fails, cache is cleared and authentication retried once

### Retry Logic

The retry mechanism handles the case where a key was recently added but not yet in cache:

1. Authentication attempt fails with "public key not authorized"
2. Cache is immediately invalidated
3. Authentication is retried with fresh keys from repository
4. If retry also fails, authentication is denied

This allows newly authorized devices to connect without waiting for cache expiry.

## Bootstrap Mode

Bootstrap mode allows the first push to an empty repository without requiring pre-configured keys.

### Race Condition Prevention

When multiple clients attempt to bootstrap simultaneously, a mutex prevents race conditions:

1. Authentication detects empty repository (no branches)
2. Server acquires bootstrap mutex lock
3. Authentication is re-checked after acquiring lock
4. If repository is still empty, push proceeds
5. If another client pushed first, normal authentication applies

This ensures only one client can perform the initial bootstrap, and subsequent clients must be authorized by the keys in the first push.

### Security Considerations

- Bootstrap mode only activates for repositories with **no branches at all**
- The first user to push gains control by adding their key to `pubkeys/`
- Repository administrators should initialize repositories in controlled environments
- For production use, consider pre-initializing repositories with authorized keys

## CLI Usage

```bash
gitd \
  --repo /path/to/bare/repo.git \
  --cert /path/to/server.crt \
  --key /path/to/server.key \
  --ca /path/to/ca.crt \
  --hostname server.example.com \
  --lfs-url http://admin:admin@lfs:8083 \
  --addr :8443 \
  --cache-ttl 5m
```

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--repo` | Yes | - | Path to bare Git repository |
| `--cert` | Yes | - | Server TLS certificate |
| `--key` | Yes | - | Server TLS private key |
| `--ca` | Yes | - | CA certificate for client trust |
| `--hostname` | Yes | - | Hostname for QR code URL |
| `--lfs-url` | Yes | - | Internal upstream Git LFS URL used by gitd proxy and pre-receive checks |
| `--decryptd-url` | Yes | - | Internal upstream decryptd URL proxied at `/decryptd` |
| `--transcoded-url` | Yes | - | Internal upstream transcoded URL proxied at `/transcoded` |
| `--addr` | No | `:8443` | Git server listen address |
| `--cache-ttl` | No | `5m` | Key cache TTL |

## Webapp Proxy mTLS Bridging

The Replycant webapp no longer runs a standalone proxy listener in normal
development. Instead, the shared Express API app is mounted inside the active
host:

- Vite development middleware for browser-based webapp development
- Electron desktop server for packaged desktop runtime

`--git-base-url` and CA certificate flags remain optional for onboarding. The
API app can boot unconfigured and receive runtime setup from the browser
through `POST /api/setup/configure` after browser-side discovery via
`POST /api/setup/discover`. The webapp proxy derives every runtime service base
from the git origin: `{origin(gitBaseUrl)}/lfs`, `/decryptd`, and `/transcoded`.

For browser clients, the proxy accepts per-request client key and client certificate headers on `/api/git/*`, `/api/lfs/*`, `/api/decryptd/*`, and `/api/transcoded/*`, uses browser-provided CA material for upstream TLS, and uses those headers to establish upstream mTLS. This keeps long-term key storage and trust bootstrap in the browser while avoiding persisted client private keys on the proxy host.

Direct-play video is the one path that cannot send those headers, because a
`<video>` element issues the request itself. For that case the browser registers
its identity once through `POST /api/setup/session` and the proxy holds it in
memory against an `httpOnly` session cookie. See
[webapp ADR-0011](https://github.com/mr-andreas/replycant/blob/main/webapp/adr/0011-session-scoped-mtls-material.md).
