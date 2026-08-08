# Cloning Repositories

This tutorial shows how to clone a Replycant repository with
`git-replycant` on Linux or macOS.

## Prerequisites

- `git`
- `git-replycant` on your `PATH`
- For default (filter-driven) LFS clones: `git-lfs`

Install `git-replycant` from the latest GitHub Release asset for your
platform, then ensure the binary is executable and on your `PATH`.

## Clone With LFS Filters (default)

By default, `git-replycant clone` configures `binary/**` through the
`replycant-crypt` filter and installs the pre-push hook that uploads
encrypted LFS objects. Use this for interactive work where you edit
files with normal git commands.

```bash
git-replycant clone https://caserver.example.com/
```

Optional arguments:

- Set a local device name override with `--device-name`
- Set a custom destination directory by adding it as the last argument

## Clone Without LFS Filters (`--no-lfs`)

Use `--no-lfs` for bulk import with `replycant-importer`. The clone still
gets manifest encryption filters and mTLS config, but it does not install
`binary/**` filters, `lfs.url`, or the pre-push hook. The importer uploads
LFS objects itself and writes pointer files directly.

```bash
git-replycant clone --no-lfs https://caserver.example.com/ my-import-repo
```

## What Happens During Clone

1. `git-replycant` initializes the local repo and sets `origin`
2. A local onboarding page is shown with a QR code
3. After device approval, it fetches and checks out the default branch
4. Filters and local Replycant config are set automatically
