# ADR-0007: Route decryptd and transcoded Through gitd

## Status
Accepted

## Context
ADR-0006 put Git LFS behind gitd's mTLS boundary, but the two media services
stayed on their own published host ports: decryptd on `:8084` and transcoded on
`:8082`. Both serve plaintext media derived from the encrypted library, and
neither performs any authentication of its own, so anyone able to reach the host
could read decrypted photos and video by guessing or observing object IDs.

A `lfs-cors` Caddy service also existed solely to add CORS headers in front of
the LFS backend for browser media requests.

## Decision
Extend the ADR-0006 pattern to every backend service. gitd now proxies three
route prefixes behind the same mTLS + `pubkeys/` gate:

- `/lfs` to the LFS backend
- `/decryptd` to decryptd
- `/transcoded` to transcoded

The LFS-specific proxy was generalized into a prefix-driven `serviceProxy`. LFS
batch `href` rewriting stays opt-in per route, because decryptd also exposes an
`/objects/` namespace and would otherwise have its responses corrupted.

Supporting changes:

- decryptd and transcoded publish no host ports. Only gitd's `:8443` (mTLS) and
  `:8080` (CA discovery) remain reachable.
- `lfs-cors` is deleted. gitd now serves the CORS headers browsers need for
  ranged, DEK-authenticated media reads, and decryptd is a server-side Go client
  that never needed them.
- decryptd talks to the LFS backend directly at `lfs:8083` instead of through the
  deleted CORS proxy.
- transcoded emits **relative** HLS playlist URIs. Absolute `/hls/...` paths
  would resolve against the wrong root once the playlist is served under a
  prefix. Relative URIs resolve correctly under gitd's `/transcoded`, the
  webapp's `/api/transcoded`, and the iOS custom playback scheme alike, which
  removes the need for playlist rewriting in any HTTP proxy.

## Consequences

### Positive
- Decrypted media is no longer reachable without a device certificate.
- One trust boundary and one published TLS port for the whole backend.
- Playlist rewriting disappears from the webapp proxy rather than being
  duplicated into gitd.

### Negative
- gitd is now on the critical path for media streaming, so its proxy must
  preserve range requests and streaming semantics.
- Clients can no longer be pointed at a media service directly for debugging;
  reproducing a media request requires a client certificate.
- Relative playlist URIs mean the playlist is only valid when fetched from its
  canonical path, since resolution now depends on the request URL.
