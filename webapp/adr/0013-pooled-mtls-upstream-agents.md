# ADR-0013: Pooled mTLS Upstream Agents in the Local Proxy

## Status
Accepted

## Context
The local webapp proxy forwards git, LFS, decryptd, and transcoded traffic to
an mTLS upstream. The existing forwarder created a new `https.Agent` for each
request, which forced repeated TLS handshakes and allowed unbounded concurrent
socket growth under bursty media traffic (for example HLS segment fetches).

ADR-0011 established session-scoped mTLS material for media requests that
cannot attach request headers. With that behavior, the same client identity is
reused across many requests in one session, which makes per-request agent
creation especially wasteful.

## Decision
The proxy keeps a bounded pool of keep-alive `https.Agent` instances and reuses
them by upstream trust and client identity.

- Agent keys are derived from `upstreamCa + keyPem + certPem` using sha256.
- The pool is an LRU cache with a maximum of 8 entries.
- Each pooled agent uses:
  - `keepAlive: true`
  - `keepAliveMsecs: 15_000`
  - `maxSockets: 32`
  - `maxFreeSockets: 4`
- Evicted agents are destroyed immediately.
- Desktop server shutdown destroys the entire pool before closing the HTTP
  server.
- When the downstream client disconnects mid-stream, the proxy destroys the
  in-flight upstream request and suppresses expected disconnect error noise.

## Consequences

### Positive
- Repeated media and git calls can reuse warm TLS connections instead of paying
  a full handshake per request.
- Explicit `maxSockets` bounds upstream concurrency and reduces file descriptor
  spikes during bursty playback.
- Client aborts release upstream sockets quickly instead of waiting for upstream
  completion.
- Pool destruction on shutdown prevents idle keep-alive sockets from outliving
  the desktop server lifecycle.

### Negative
- The proxy now retains private key material in memory for the pool lifetime
  (bounded by LRU entry count), not only for one request.
- Connection reuse introduces a small amount of lifecycle complexity (pool
  ownership and teardown) in app/server wiring.
