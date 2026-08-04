# Cloning Repositories

This tutorial shows how to clone a Replycant repository with
`git-replycant` on Linux or macOS.

## Prerequisites

- `git`
- `git-replycant` on your `PATH`
- A CA certificate file for your Replycant server
- For LFS repos: `git-lfs`

Install `git-replycant` from the latest GitHub Release asset for your
platform, then ensure the binary is executable and on your `PATH`.

## Clone Without LFS

Use this for repos that only contain manifest content.

```bash
git-replycant clone --ca-file /path/to/gitd-ca.pem https://git.example.com/my-repo.git
```

Optional arguments:

- Set a local device name override with `--device-name`
- Set a custom destination directory by adding it as the last argument

Example:

```bash
git-replycant clone \
  --ca-file /path/to/gitd-ca.pem \
  --device-name "laptop-linux" \
  https://git.example.com/my-repo.git \
  my-replycant-repo
```

## Clone With LFS

Use this when the repo contains `binary/**` content stored in Git LFS.

```bash
git-replycant clone \
  --ca-file /path/to/gitd-ca.pem \
  --lfs-url https://lfs.example.com/my-repo.git/info/lfs \
  https://git.example.com/my-repo.git
```

With `--lfs-url`, `git-replycant` configures local LFS settings and installs the Replycant pre-push hook for LFS uploads.

## What Happens During Clone

1. `git-replycant` initializes the local repo and sets `origin`
2. A local onboarding page is shown with a QR code
3. After device approval, it fetches and checks out the default branch
4. Filters and local Replycant config are set automatically
