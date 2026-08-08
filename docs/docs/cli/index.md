# CLI

This section covers using Replycant CLI tools on Linux and macOS.

Download `git-replycant` and `replycant-importer` binaries from the
project GitHub Releases page, then place them on your `PATH`.

## mDNS fallback for `.local`

`git-replycant` falls back to multicast DNS resolution for `.local`
hostnames when the system DNS resolver fails. This keeps clone
discovery and LFS pre-push requests working in static Go binaries where
NSS-based mDNS resolution is not available.

## Tutorials

- [Cloning Repositories](./cloning.md)
- [Importing Media](./importing.md)
- [Pushing an LFS Repository to a Backup Remote](./pushing-lfs.md)
