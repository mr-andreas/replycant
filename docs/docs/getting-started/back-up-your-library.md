---
sidebar_position: 5
---

# Back up your library

A backup is a full clone on a second computer, kept current with `git pull`. The clone downloads every photo and video, so this computer holds its own copy of the library if the server is lost.

![What a backup clone stores, and the pull that keeps it current](./back-up-your-library/backup-contents.drawio.svg)

## Make the first copy

On the backup computer, install `git`, `git-lfs`, and `git-replycant` as described in [Clone your library](./clone-your-library.md). Then clone with the defaults, which turns LFS downloads on:

```bash
git-replycant clone backup
```

Open the address the command prints and approve the QR code from the iPhone, the same way as any other device ([Approve a new device](./start-a-server.md#approve-a-new-device)). The backup computer becomes an authorized device of the library, and the clone checks out every photo and video in decrypted form.

`--no-lfs` is the wrong mode here. That clone stores the history and leaves the photos on the server.

## Keep it current

`git pull` downloads commits made since the last run, including new photos. Run it on a schedule. This hourly crontab entry fast-forwards the clone and refuses to run if someone has committed inside the backup:

```bash
0 * * * * cd /srv/replycant-backup && git pull --ff-only
```

Change the path to wherever you cloned. `cron` often has a short `PATH`, and the pull needs `git`, `git-lfs`, `git-replycant`, and `git-remote-replycant` on it. Put the directory that holds those binaries in front of the command when they are somewhere else:

```bash
0 * * * * PATH=/usr/local/bin:$PATH cd /srv/replycant-backup && git pull --ff-only
```

Nothing has to stay running between pulls. The connection to the library starts for the pull and exits afterward.

## What the copy contains

The `.git` directory holds the full history of the library and the encrypted photos and videos, under `.git/lfs/objects`. The working tree holds the same photos and videos decrypted, which is what makes the copy usable on its own. Plan for roughly twice the size of the media.

A pull downloads the media referenced by the current branch. Photos that were removed from the library before this computer ever pulled them are part of the history as metadata, and their bytes stay on the server.

## Treat it as a copy

Checkout writes decrypted photos into the working tree, so keep the clone on an encrypted disk.

Leave the clone as a pull-only copy. Commits or pushes made here would publish this computer's working tree back to the library.

The backup keeps working for as long as this computer stays an authorized device. Removing its key from `pubkeys/` ends that, and later pulls fail until the computer is approved again. [Device onboarding](../gitdb/device-onboarding.md) covers how devices are authorized and removed.
