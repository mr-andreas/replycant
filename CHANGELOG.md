# Changelog

## Unreleased

### Breaking changes

- replycant-importer: requires a `git-replycant clone --no-lfs` worktree; full-LFS clones with `binary/**` filters or `lfs.url` are rejected
- server: replace the separate `lfs-test-server` service and `--lfs-url` proxy with a native file-backed LFS store in gitd (`--lfs-dir`); wipe existing LFS volumes (or point `--lfs-dir` at a compatible `objects/` tree), remove the `lfs` compose service, and point decryptd at `http://gitd:8085/lfs`; concurrent uploads of the same object now get `409 Conflict` instead of blocking
- server: transcoded no longer depends on nvidia gpu reservation or cuda runtime; redeploy and expect software-only transcoding

### Features

- add regenerable iOS and Electron product screenshots in the README (`make readme-screenshots`)
- iosapp: recover access by scanning a recovery QR from Connect to an existing library
- iosapp: adds recovery key creation, deep-link and QR recovery flows, and fresh-install repository recovery with key re-enrollment
- replycant-importer: encrypts binaries and uploads them to LFS before commit, writing only pointer files into the worktree for much faster import/rebase
- replycant-importer: starts encrypting and uploading while the source tree is still being scanned; progress shows `(calculating, N found)` until the scan finishes
- server: git and CA listen ports can be set with `REPLYCANT_GIT_PORT` and `REPLYCANT_CA_PORT`; already-linked devices need re-onboarding or a stored URL update after a port change
- server: the advertised hostname can be set with `REPLYCANT_HOSTNAME` instead of the auto-detected `<hostname>.local`; already-linked devices need re-onboarding after a change
- server: publish arm64 container images so the stack runs on arm hosts
- webapp: show a progress bar in the header when syncing takes longer than two seconds

### Fixes

- iosapp: show progress while revoking the used recovery key after recovery
- iosapp: stop sync from wedging after deleting a recovery key; rebases are now deterministic instead of re-stamping commits with a new timestamp, and the app recovers automatically from duplicated commits
- iosapp: explain that a recovery key is a password-protected link or QR code for restoring access
- iosapp: drop the fresh-install restore sentence from the recovery key settings description
- iosapp: remove the device name and public-key labels from the connect QR screen
- iosapp: show an explicit delete button and confirmation for existing recovery keys
- iosapp: generate a simulator device key when bundled credentials are missing so recovery can enroll a new device
- iosapp: say a recovery key was deleted from the server instead of showing an HTTP 401 error
- iosapp: recovery no longer builds the media index twice, roughly halving recovery time and pushing the new device key before indexing starts
- iosapp: fix recovery failing with a disk I/O error while rebuilding the media index
- iosapp: say the recovery password is incorrect instead of showing a crypto error
- iosapp: hide the password strength meter when unlocking with a recovery key
- iosapp: show a success icon on the recovery-key created step and keep Done locked until the key is shared
- iosapp: share a recovery key as titled text plus a QR card so mail and notes-style destinations can receive both as inline content
- iosapp: make recovery password fields visible and show password strength and mismatch feedback
- iosapp: clear the settings recovery warning as soon as a recovery key is created
- iosapp: stop video playback when a video opened by swiping is dismissed
- iosapp: fix random crash while browsing timeline media
- iosapp: timeline and photo sync now recover after resetting local state instead of staying empty until the app is relaunched
- iosapp: zoomed fullscreen photos no longer reset or shrink when new photos sync in
- replycant-importer: failed or interrupted commits no longer leave staged-but-deleted files that permanently block push/rebase
- replycant-importer: ctrl+c now stops in-flight work immediately, flushes pending commits, and a second ctrl+c cancels the flush
- server: revoking a device or recovery key now blocks it immediately instead of leaving it usable for up to five minutes
- webapp: fix timeline tiles staying blank after switching commits until you scroll
