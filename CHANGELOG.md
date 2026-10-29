# Changelog

## Unreleased

### Features

#### iOS app

- read the application log in Settings and share it as a text file
- turn on photo and video upload from the timeline or Settings. Uploads start on Wi-Fi while the app is open, and also while the phone is charging with the app closed, smallest files first. The timeline shows progress. If uploads have not completed for 7 days, Replycant can send one reminder. The Upload page in Settings holds the switch and lists each charging run with when it started and stopped, how many files and bytes it uploaded, how many were left, and the result
- share a photo or video, or save it to the camera roll, from the full-screen viewer, and saving an item already in Photos says so instead of adding a copy

### Fixes

#### iOS app

- rotating the timeline keeps the same photos on screen
- landscape timeline thumbnails stay about the portrait size and run to the edges of the screen
- opening the app after a charging upload reconnects, instead of staying on a tailnet whose sockets were reclaimed while the phone was locked
- sharing the application log opens without freezing, and the file reaches the app you pick
- the timeline and full-screen zoom stay responsive while photos upload
- photos no longer stay as grey placeholders after another device uploads a large batch
- tapping a photo or video in the timeline opens it on the first tap

#### Desktop app

- the map zooms continuously with the touchpad, scaling in place instead of flashing
- the map keeps its place, zoom, and open place when you leave it and come back

#### git-replycant

- a fetch or push no longer fails when it has to start the repository's tailnet agent

#### replycant-importer

- photo GPS latitude is no longer stored as 0 when the photo also has an interoperability block

## 0.5.0 - 2026-10-18

### Features

#### Desktop app

- browse your library on a map of places, open the photos from one place, and press Escape to return to the map

### Fixes

- a git fetch or push no longer occasionally hangs for two minutes and fails while the repository's tailnet connection starts

#### iOS app

- the Map tab opens on the area where most photos were taken instead of the whole world
- a device closed while joining a library now returns to setup instead of a resync screen that says "no error"
- hiding the month sidebar while viewing the oldest photos no longer jumps the timeline

## 0.4.0 - 2026-10-15

### Features

#### iOS app

- a Map tab groups photos by place, each group shows one of its own photos and points at the exact spot that photo was taken, and tapping a place shows only those photos
- after an update that changes the local index, the app rebuilds it from the library on launch

### Fixes

#### iOS app

- the timeline keeps the photos on screen in place while sync adds older photos
- a full-screen photo that fails to load now shows the error and a retry button instead of spinning forever
- tapping the Timeline tab or the status bar jumps to the newest photos instead of the oldest
- tapping a month in the sidebar keeps that month selected
- month names in the sidebar stay on one line at large text sizes
- the Connection status in Settings stays readable at large text sizes
- upload says when Photos access is off instead of showing an internal error
- the month sidebar highlights the month of the photos at the top of the timeline
- photo details show HEIC, JPEG, or MOV instead of a type identifier

#### replycant-importer

- the importer reports files it failed to import and exits with an error instead of succeeding
- videos now keep their GPS location

## 0.3.1 - 2026-10-12

### Fixes

#### Desktop app

- the Windows release job no longer fails sidecar path checks that assumed macOS path separators

## 0.3.0 - 2026-10-11

### Breaking changes

- all client-to-server traffic now runs over a private tailnet, so every device must be re-onboarded. The first device must be the iOS app: open `http://<server>:8080` from the server or anywhere on the LAN and scan a one-time join QR. The page stops handing out join codes once the first device has joined; set `REPLYCANT_CA_BIND=127.0.0.1` to keep it on the server host. Later devices, including every desktop, show a pairing QR to an already-paired device; the browser build cannot reach a tailnet deployment. The CA page and pairing record no longer carry a gitd URL or tailnet name — clients always use `https://gitd.replycant.internal:8443`. Wipe existing pairings; the QR shape and pairing payload both changed. The control-plane hostname includes a shard label (`{ca-hash}.s{NN}.tunnel.replycant.com`). A plain `docker compose up` publishes the control plane through the hosted relay. Pairing records are authenticated only under the secret from the pairing QR and are delivered only through the discovery API
- LAN-only servers are gone: the server always runs the tailnet and no longer publishes a Git port, so `REPLYCANT_GIT_PORT` and `REPLYCANT_HOSTNAME` have no effect. Wipe state and pair every device over the tailnet. Recovery keys created before this change no longer open; create a new one once the phone is paired

#### Desktop app

- the browser build now shows a "desktop app required" screen instead of onboarding, because only the desktop app can join the tailnet. Use the desktop app

#### git-replycant

- `clone` no longer takes a server URL and no longer connects directly. Run `git-replycant clone` and approve the pairing QR from a device already on the tailnet. Existing command-line clones have to be cloned again. The release archive's `git-remote-replycant` symlink has to be on `PATH`, because that is how git reaches the repository

### Features

- reach your library from anywhere without forwarding a router port or running dynamic dns. devices join a private network with the server, can reach the server but not each other, media travels directly between them where possible, and the hosted services that make the introduction cannot read any of it. membership follows the device keys in the library: removing a device's key takes it off the network right away without disconnecting the other devices, and the server can lose its network database (delete `headscale/lib` and run `docker compose up`) without anyone pairing again. a recovery key restores the library onto a fresh phone over the same network

#### iOS app

- the library opens immediately at launch instead of waiting for the network, and a notice shows when the library cannot be reached
- on mobile data or in Low Data Mode, videos no longer autoplay and uploads ask before starting; both warn how much data full-quality media uses, and an upload started on Wi-Fi pauses if the phone switches to mobile data
- show how this device reaches the library — connected or not, whether the server is reached directly or through a relay, and whether peers are online — on the Connection page in Settings

#### Desktop app

- show how this device reaches the library — connected or not, whether the server is reached directly or through a relay, and whether peers are online — in the settings pane
- the settings pane is titled Settings and grouped into collapsible Sync, Commits, Connectivity, and Data management sections

#### git-replycant

- fetch, push, and LFS share one background tailnet connection per repository. It starts when a command needs the network and exits after a few minutes of idle time

#### replycant-importer

- LFS uploads go through that same tailnet connection, and a repository that was not cloned with `git-replycant` is refused

### Fixes

#### iOS app

- the connection problems banner now appears whenever the phone loses its network or cannot reach your library, not only while connecting at launch
- photos opened before the app finished connecting to your library now load once the connection is up instead of spinning forever
- after the phone has been locked for a while, photo upload and sync connect again instead of failing while Settings still says the device is connected
- setup and photo upload now say what they are doing instead of showing a silent spinner
- linking a new device no longer freezes after the pairing QR is scanned

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
