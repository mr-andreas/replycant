# Changelog

## Unreleased

### Breaking changes

- replycant-importer: requires a `git-replycant clone --no-lfs` worktree; full-LFS clones with `binary/**` filters or `lfs.url` are rejected
- server: replace the separate `lfs-test-server` service and `--lfs-url` proxy with a native file-backed LFS store in gitd (`--lfs-dir`); wipe existing LFS volumes (or point `--lfs-dir` at a compatible `objects/` tree), remove the `lfs` compose service, and point decryptd at `http://gitd:8085/lfs`; concurrent uploads of the same object now get `409 Conflict` instead of blocking
- server: transcoded no longer depends on nvidia gpu reservation or cuda runtime; redeploy and expect software-only transcoding

### Features

- add regenerable iOS and Electron product screenshots in the README (`make readme-screenshots`)
- replycant-importer: encrypts binaries and uploads them to LFS before commit, writing only pointer files into the worktree for much faster import/rebase
- replycant-importer: starts encrypting and uploading while the source tree is still being scanned; progress shows `(calculating, N found)` until the scan finishes
- server: git and CA listen ports can be set with `REPLYCANT_GIT_PORT` and `REPLYCANT_CA_PORT`; already-linked devices need re-onboarding or a stored URL update after a port change
- server: publish arm64 container images so the stack runs on arm hosts
- webapp: show a progress bar in the header when syncing takes longer than two seconds

### Fixes

- iosapp: stop video playback when a video opened by swiping is dismissed
- iosapp: fix random crash while browsing timeline media
- iosapp: timeline and photo sync now recover after resetting local state instead of staying empty until the app is relaunched
- replycant-importer: failed or interrupted commits no longer leave staged-but-deleted files that permanently block push/rebase
- replycant-importer: ctrl+c now stops in-flight work immediately, flushes pending commits, and a second ctrl+c cancels the flush
- webapp: fix timeline tiles staying blank after switching commits until you scroll
