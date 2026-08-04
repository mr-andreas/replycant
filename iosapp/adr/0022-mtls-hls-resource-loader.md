# ADR-0022: Custom-Scheme Resource Loader for mTLS HLS Playback

## Status
Accepted

## Context
Server ADR-0007 moved decryptd and transcoded behind gitd's mTLS endpoint. Both
playback paths on iOS now need to present the device certificate on every media
request.

Direct play already routed its requests through `DirectPlayResourceLoader`, an
`AVAssetResourceLoaderDelegate` on the `replycant-dplay` scheme, so it only
needed a client identity added to its `URLSession`.

HLS transcode did not. `AVURLAsset(url:)` hands the playlist to AVFoundation,
which fetches the playlist, its variants, and every segment with its own
internal HTTP stack. That stack accepts `AVURLAssetHTTPHeaderFieldsKey` but
offers no way to supply a client certificate, so native HLS playback cannot
authenticate against gitd at all.

## Decision
Add `HLSResourceLoader`, an `AVAssetResourceLoaderDelegate` registered against a
`replycant-hls` custom scheme, modeled on the existing direct-play loader.

- The playlist URL handed to `AVURLAsset` is rewritten to `replycant-hls://`,
  which makes AVFoundation delegate every sub-request to us instead of fetching
  it itself.
- Each sub-request is mapped back to `https://` and issued through a
  `URLSession` using the shared `MTLSURLSessionAuthDelegate`, which presents the
  device identity and pins the server chain to the onboarded CA. DEK headers are
  forwarded on every request.
- `contentInformationRequest.contentType` is set per response
  (`public.m3u8-playlist` or `public.mpeg-2-transport-stream`), since
  AVFoundation never sees the real URL extension.
- No playlist body rewriting is performed. transcoded emits relative playlist
  URIs (server ADR-0007), so AVFoundation resolves variants and segments against
  the custom-scheme base URL and they arrive here already under
  `replycant-hls://`. This is the main reason for the relative-URI change.

The challenge-handling logic that LFS already had was promoted out of
`GitLFS.swift` into a shared public `MTLSURLSessionAuthDelegate` in
LibGit2Package, so Git, LFS, direct play, and HLS all authenticate identically
rather than carrying four copies of the same trust evaluation.

## Consequences

### Positive
- HLS playback works against an mTLS-only backend with no server-side change.
- All four client paths share one implementation of certificate pinning and
  client-identity presentation.
- Relative playlist URIs mean the same playlist bytes work for iOS, the webapp,
  and direct gitd access.

### Negative
- Intercepting a full HLS session through `AVAssetResourceLoaderDelegate` is
  widely relied upon but is not a formally documented AVFoundation guarantee. If
  a future OS rejects the custom scheme, the fallback is an on-device HTTP relay
  bound to `127.0.0.1` that terminates mTLS and serves plain HTTP to AVPlayer.
- Segments are buffered in full before being handed to AVFoundation, rather than
  streamed incrementally as the direct-play loader does. Segment sizes make this
  acceptable, but it is a behavioral difference worth revisiting if segment
  duration grows.
