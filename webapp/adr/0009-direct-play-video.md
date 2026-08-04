# 0009 — Direct-play video routing with strategy selector

**Status:** Accepted

## Context

Web video playback currently goes through `/api/transcoded/*` and relies on
HLS segments generated on demand by `transcoded` with ffmpeg. This guarantees
playback compatibility but introduces re-encode latency, extra CPU/GPU usage,
and additional moving parts (`transcoded` plus segment generation) for every
video play.

We want an immediate direct-play path in the webapp that streams decrypted media
bytes from `decryptd` without HLS, transcoding, or transmuxing.

At the same time, playback mode selection must be centralized so we can later
switch between:

- direct play
- direct stream
- transcode

without refactoring callsites again.

## Decision

1. Add a playback strategy selector in `webapp/src/lib/playback.ts` with
   `PlaybackStrategy = "directPlay" | "directStream" | "transcode"`.
2. For now, `selectPlaybackStrategy()` always returns `"directPlay"`.
3. Route web video URLs to `/api/decryptd/objects/{oid}` in direct-play mode.
4. Add a web proxy route `/api/decryptd/*` that forwards to `decryptd`.
5. Because native `<video src="...">` requests cannot attach custom headers,
   pass `dek` and `chunkSize` as query params on the same-origin URL and map
   them to `X-Replycant-DEK` and `X-Replycant-Chunk-Size` headers in the proxy
   before forwarding upstream.
6. Keep the HLS code path available behind the strategy branch for future
   `"transcode"` use.

## Consequences

**Positive:**

- Videos start from direct object streaming without ffmpeg segment generation.
- The app gains a single strategy switch point for future direct-stream and
  transcode policy.
- Existing `decryptd` plaintext range support is reused directly for seeking.

**Negative:**

- DEK material is now present in same-origin request query params for direct
  play, which increases sensitivity to URL logging and telemetry.
- Native direct play depends on browser codec/container support and may fail
  for files that HLS transcoding would normalize.
