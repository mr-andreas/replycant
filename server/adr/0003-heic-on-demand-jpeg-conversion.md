# 0003 - HEIC on-demand JPEG conversion for browser display

## Status
Accepted

## Context
Chrome and Firefox do not reliably decode HEIC/HEIF originals served directly from Git LFS, which causes fullscreen rendering failures for affected photos. Storing duplicate converted assets in-repo would increase storage and synchronization cost for every HEIC file.

## Decision
Add on-demand conversion in the backend media service:

- Expose `/image/{sha256}.jpg` in the `transcoded` service.
- Fetch source objects from LFS by SHA256 OID and convert them with `ffmpeg` to JPEG at request time.
- Keep repository storage unchanged (HEIC originals remain source-of-truth).
- Route webapp HEIC/HEIF display requests to the conversion endpoint, while non-HEIC assets continue using existing blob download behavior.

## Consequences
- Browser users can display HEIC originals without changing stored media formats.
- Conversion cost shifts to request time and increases CPU usage under HEIC-heavy viewing workloads.
- The conversion endpoint introduces an additional availability dependency (`transcoded`) for HEIC display.
- No media duplication is introduced in Git/LFS, preserving current sync/storage behavior.
