# ADR-0020: Default fullscreen video playback to direct decryptd streaming

## Status

Accepted

## Context

iOS fullscreen video playback currently routes every video through
`transcoded` HLS playlists on port 8082. This guarantees compatibility but
adds transcode startup latency and unnecessary server work for assets that can
already play natively.

The app already includes a playback strategy enum and settings UI scaffolding,
but the selector is not connected to the runtime playback path and the
settings page is not reachable from Settings.

We also need one central selector hook for a future bandwidth-aware policy
that can switch between direct and transcoded playback without refactoring all
call sites again.

## Decision

1. Fullscreen video playback now branches through
   `PlaybackSettingsManager.selectPlaybackMethod(for:)`.
2. Default mode remains `directPlay`, which streams from decryptd:
   `http://{host}:8084/objects/{oid}`.
3. `transcode` mode preserves the existing HLS route:
   `http://{host}:8082/hls/{oid}/{duration}/playlist.m3u8`.
4. `PlaybackSettingsView` is linked from `SettingsView` so users can switch
   between modes.
5. The selector remains a stub that currently returns the persisted user
   preference until dynamic bandwidth-based selection is implemented.
6. Playback must stay streaming-only: AVPlayer consumes network responses
   progressively, and no pre-buffering of full files to memory or disk is
   introduced before playback starts.

## Consequences

### Positive

- Direct play is the default, reducing startup delay when native playback is
  possible.
- Strategy selection is centralized, enabling future adaptive bandwidth logic
  with minimal callsite churn.
- Users can explicitly opt into transcoding from Settings when needed.
- Direct-play tests can exercise byte-range streaming behavior through the test
  server `/objects/{oid}` route.

### Negative

- Native direct play depends on codec/container support and may fail for
  formats HLS transcoding could normalize.
- Playback logic now has two URL routes and mode-specific AVPlayer tuning,
  increasing branch complexity in the fullscreen loader.
