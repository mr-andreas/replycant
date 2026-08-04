# ADR-0011: Session-Scoped mTLS Material for Media Requests

## Status
Accepted

## Context
Browsers cannot perform mTLS with a key held in JavaScript, so the webapp's local
proxy authenticates to gitd on the browser's behalf. Every proxied route takes
the browser's identity from per-request `x-replycant-client-key` and
`x-replycant-client-cert` headers.

Server ADR-0007 moved decryptd and transcoded behind gitd's mTLS boundary, which
means media requests now need that identity too. Most do fine: image loads and
HLS playback go through `fetch` and hls.js, both of which can set headers.
Direct-play video does not — it sets `video.src` and lets the media element issue
the request, and a media element cannot attach custom headers.

## Decision
The proxy accepts a second source of mTLS material, scoped to a session.

- After unlocking its identity, the browser POSTs the same base64 PEM pair to
  `POST /api/setup/session`. The proxy validates it, mints a session id, and
  returns it as an `httpOnly`, `SameSite=Strict` cookie.
- The material is held in proxy memory only, keyed by session id. Nothing is
  written to disk.
- The forwarder resolves credentials as: per-request headers first, session
  material second. Per-request headers keep taking precedence so a request that
  carries its own identity is never attributed to another browser's session, and
  `/api/git` and `/api/lfs` behavior is unchanged.
- Because the store is in memory, a proxy restart invalidates sessions. The
  direct-play path re-registers once and retries when a video element reports an
  error, so playback recovers without a page reload.

## Consequences

### Positive
- Direct-play video works against an mTLS-only backend without a service worker
  or Media Source Extensions pipeline.
- Concurrent browsers against the same proxy stay attributed to their own device
  certificates.
- Key material has a bounded lifetime: it lives only as long as the proxy
  process.

### Negative
- The proxy holds private key material in memory, where previously it only saw it
  per request. The desktop and localhost deployment model is what makes this
  acceptable; it would not be for a shared proxy.
- Anything able to send the session cookie can drive authenticated media
  requests, so the cookie is `httpOnly` and `SameSite=Strict` to keep it out of
  script and cross-site reach.
- There are now two credential paths to reason about instead of one.
