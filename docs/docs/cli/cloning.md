# Cloning Repositories

This tutorial shows how to clone a Replycant repository with
`git-replycant` on Linux or macOS.

## Prerequisites

- `git`
- `git-lfs` for the default filter-driven clone
- `git-replycant` on your `PATH`
- `git-remote-replycant` on your `PATH`, as a symlink to that same binary

Install `git-replycant` from the latest GitHub Release asset for your
platform. The archive includes the `git-remote-replycant` symlink. Git
uses that name to reach the repository over the tailnet; without it,
clone stops before pairing.

## Clone With LFS Filters (default)

By default, `git-replycant clone` configures `binary/**` through the
`replycant-crypt` filter and installs the pre-push hook that uploads
encrypted LFS objects. Use this for interactive work where you edit
files with normal git commands.

```bash
git-replycant clone
```

The directory defaults to `replycant`. Pass one to choose another:

```bash
git-replycant clone my-library
```

Optional arguments:

- `--device-name` sets the name this machine uses on the tailnet
- `--discovery-url` defaults to `https://discovery.replycant.com`

There is no server URL. gitd is always
`https://gitd.replycant.internal:8443`, and that name only resolves
after this machine has joined the tailnet.

## Clone Without LFS Filters (`--no-lfs`)

Use `--no-lfs` for bulk import with `replycant-importer`. The clone still
gets manifest encryption filters and mTLS config, but it does not install
`binary/**` filters, `lfs.url`, or the pre-push hook. The importer uploads
LFS objects itself and writes pointer files directly.

```bash
git-replycant clone --no-lfs my-import-repo
```

## What Happens During Clone

1. `git-replycant` initializes the local repo and sets `origin` to the tailnet gitd URL
2. A page on `127.0.0.1` shows a pairing QR code. It is loopback-only because it carries the pairing secret
3. An already-paired device approves that QR. This machine polls discovery until the sealed record appears, then joins the tailnet
4. After the approving device has committed this machine's key, clone fetches and checks out the default branch
5. Filters and local Replycant config are set automatically

Later `git fetch`, `git push`, and LFS all reuse one background agent for
that repository. It listens only on loopback, starts when a command needs
the network, and exits after a few minutes with nothing to proxy.
