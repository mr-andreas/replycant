# ADR-0021: Prefer local photo library for media viewing

## Status

Accepted

## Context

Timeline thumbnails already support an optional local-first lookup using
`Original.spec.localID` and PhotoKit, but fullscreen photo and video
views always load from remote sources:

- photos: LFS pointer -> LFS download -> decrypt -> decode
- videos: decryptd direct play or HLS transcode

For media captured on the current device, this introduces avoidable
latency while the same bytes are already present in the local Photos
library.

The app must continue to work when Photos permission is unavailable
(not requested yet, denied, or restricted), and development workflows
still rely on the existing local-media toggle to measure remote-path
performance.

## Decision

Adopt a local-first strategy for media viewing whenever local access is
available, with remote fallback preserved.

- Keep `CacheSettingsManager.localThumbnailsEnabled` as the master
  feature flag for local-media loading.
- Gate all local lookups behind:
  - `localThumbnailsEnabled == true`
  - `photoLibrary.isAuthorized == true`
  - non-empty `Original.spec.localID`
- Add PhotoLibrary abstraction APIs for local fullscreen sources:
  - full-resolution image bytes by local identifier
  - local video file URL by local identifier
- Fullscreen photos:
  - try local full-resolution image first
  - fallback to existing LFS path on miss/failure
- Fullscreen videos:
  - try local video URL first and build `AVPlayer` from local `AVURLAsset`
  - fallback to existing decryptd/HLS path on miss/failure
- Fullscreen neighbor preloading uses the same local-first photo loader
  path before LFS.

Local lookups use network-disabled PhotoKit requests, so iCloud-only
assets return `nil` and intentionally trigger remote fallback.

## Consequences

### Positive

- Faster fullscreen open and video start for media present on-device.
- Lower network and backend load for local-device viewing sessions.
- No behavior regression when Photos permission is missing; remote
  fallback remains intact.
- Developers can still disable local-first behavior via existing toggle
  for performance testing.

### Negative

- Fullscreen media paths now depend on PhotoKit availability checks and
  localID correctness in addition to existing remote loading logic.
- Local and remote playback paths can produce different startup behavior
  depending on device state (local file present vs absent).
