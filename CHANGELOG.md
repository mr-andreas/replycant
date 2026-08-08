# Changelog

## Unreleased

### Breaking changes

- replycant-importer: requires a `git-replycant clone --no-lfs` worktree; full-LFS clones with `binary/**` filters or `lfs.url` are rejected
- server: transcoded no longer depends on nvidia gpu reservation or cuda runtime; redeploy and expect software-only transcoding

### Features

- replycant-importer: encrypts binaries and uploads them to LFS before commit, writing only pointer files into the worktree for much faster import/rebase

### Fixes

- iosapp: timeline and photo sync now recover after resetting local state instead of staying empty until the app is relaunched
