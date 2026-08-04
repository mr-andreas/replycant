# 0007 - Electron desktop packaging

## Status

Accepted

## Context

The webapp currently runs as a Vite frontend plus a local Express proxy that owns `/api` routes needed for git, LFS, and transcoded media access. We need downloadable desktop packages for Linux, macOS, and Windows without changing core web runtime assumptions.

## Decision

Use Electron as the desktop shell and package with `electron-builder`.

The desktop runtime starts a loopback Express server that:

- reuses the existing proxy routes from `server/app.ts`
- serves built Vite assets from `dist`
- keeps the renderer on a localhost HTTP origin so `/api` behavior stays unchanged

Packaging targets:

- Linux: `AppImage`, `deb`
- macOS: `dmg`
- Windows: `nsis`, `portable`

Release automation builds native artifacts on Linux, macOS, and Windows CI
runners and publishes generated files into a unified repository release tag
that also carries server assets.

## Consequences

Positive:

- Desktop delivery uses widely available installer formats across all target OSes.
- The renderer keeps existing same-origin `/api` behavior and avoids a `file://` rewrite path.
- Proxy behavior is shared between web and desktop, reducing duplicated logic.

Negative:

- Build and release pipelines become heavier because each OS builds native artifacts.
- Code-signing and notarization are still required for best end-user install UX on macOS and Windows.
