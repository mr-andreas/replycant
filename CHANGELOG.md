# Changelog

## Unreleased

### Breaking changes

- all client-to-server traffic now runs over a private tailnet, so every device must be re-onboarded. The first device visits `http://127.0.0.1:8080` on the server host and scans (or fetches) a one-time join QR; later devices still show a pairing QR to an already-paired device. The CA page and pairing record no longer carry a gitd URL or tailnet name — clients always use `https://gitd.replycant.internal:8443`. Wipe existing pairings; the QR shape and pairing payload both changed. The control-plane hostname includes a shard label (`{ca-hash}.s{NN}.tunnel.replycant.com`). A plain `docker compose up` publishes the control plane through the hosted relay. Set `REPLYCANT_HEADSCALE_URL` and `REPLYCANT_HSPROXY_BIND=0.0.0.0` and start with `--scale tunnel-agent=0` to expose it through your own router instead

### Features

- reach your library from anywhere without forwarding a router port or running dynamic dns. devices join a private network with the server, can reach the server but not each other, media travels directly between them where possible, and the hosted services that make the introduction cannot read any of it

#### iOS app

- show how this device reaches the library — connected or not, which control path it is using, whether the server is reached directly or through a relay, and whether peers are online — in Settings

#### Desktop app

- show how this device reaches the library — connected or not, which control path it is using, whether the server is reached directly or through a relay, and whether peers are online — in the settings pane

### Fixes

#### iOS app

- setup and photo upload now say what they are doing instead of showing a silent spinner
- linking a new device no longer freezes after the pairing QR is scanned
- git fetch and first video load no longer hitch while installing the tailnet proxy

#### Server

- the hosted tunnel agent now trusts the relay's registration certificate, so a first device can join without a forwarded port

## 0.2.1 - 2026-09-07

### Fixes

#### Desktop app

- signed macOS desktop releases work again

## 0.2.0 - 2026-09-07

### Breaking changes

#### Server

- repositories now carry plaintext `gitdb/version` pinned to `1`; a missing marker is treated as version `0` so old alpha libraries keep working until a migration writes `1`. If the library is newer, update the app; if it is older, run the migration tool; if a previously synced marker disappears, restore it
- replace the separate `lfs-test-server` service and `--lfs-url` proxy with a native file-backed LFS store in gitd (`--lfs-dir`); wipe existing LFS volumes (or point `--lfs-dir` at a compatible `objects/` tree), remove the `lfs` compose service, and point decryptd at `http://gitd:8085/lfs`; concurrent uploads of the same object now get `409 Conflict` instead of blocking
- transcoded no longer depends on nvidia gpu reservation or cuda runtime; redeploy and expect software-only transcoding

#### replycant-importer

- requires a `git-replycant clone --no-lfs` worktree; full-LFS clones with `binary/**` filters or `lfs.url` are rejected

### Features

- add regenerable iOS and Electron product screenshots in the README (`make readme-screenshots`)
- rebuild the local cache when a library format change is pulled, and on iOS discard unpublished local commits when that change cannot be rebased

#### iOS app

- create a password-protected recovery key, share it as a link or QR code, and use it to restore access to your library on a new or wiped device

#### Desktop app

- show a progress bar in the header when syncing takes longer than two seconds

#### Server

- git and CA listen ports can be set with `REPLYCANT_GIT_PORT` and `REPLYCANT_CA_PORT`; already-linked devices need re-onboarding or a stored URL update after a port change
- the advertised hostname can be set with `REPLYCANT_HOSTNAME` instead of the auto-detected `<hostname>.local`; already-linked devices need re-onboarding after a change
- publish arm64 container images so the stack runs on arm hosts

#### replycant-importer

- encrypts binaries and uploads them to LFS before commit, writing only pointer files into the worktree for much faster import/rebase
- starts encrypting and uploading while the source tree is still being scanned; progress shows `(calculating, N found)` until the scan finishes

### Fixes

#### iOS app

- photo uploads now refuse an unsupported `gitdb/version` instead of proceeding
- remove the device name and public-key labels from the connect QR screen
- stop video playback when a video opened by swiping is dismissed
- fix random crash while browsing timeline media
- timeline and photo sync now recover after resetting local state instead of staying empty until the app is relaunched
- zoomed fullscreen photos no longer reset or shrink when new photos sync in

#### Desktop app

- fix timeline tiles staying blank after switching commits until you scroll
- stop reporting a false database format tampering error when gitdb/version could not be read or the local cache still stored a compiled format pin

#### Server

- refuse to auto-detect Docker VM hostnames such as docker-desktop; set REPLYCANT_HOSTNAME on Docker Desktop
- revoking a device or recovery key now blocks it immediately instead of leaving it usable for up to five minutes

#### replycant-importer

- failed or interrupted commits no longer leave staged-but-deleted files that permanently block push/rebase
- ctrl+c now stops in-flight work immediately, flushes pending commits, and a second ctrl+c cancels the flush
