# Changelog

## Unreleased

### Breaking changes

- replycant-importer: requires a `git-replycant clone --no-lfs` worktree; full-LFS clones with `binary/**` filters or `lfs.url` are rejected
- server: transcoded no longer depends on nvidia gpu reservation or cuda runtime; redeploy and expect software-only transcoding

### Features

- replycant-importer: encrypts binaries and uploads them to LFS before commit, writing only pointer files into the worktree for much faster import/rebase
- replycant-importer: starts encrypting and uploading while the source tree is still being scanned; progress shows `(calculating, N found)` until the scan finishes

### Fixes

- replycant-importer: ctrl+c now stops in-flight work immediately, flushes pending commits, and a second ctrl+c cancels the flush
- iosapp: timeline and photo sync now recover after resetting local state instead of staying empty until the app is relaunched
