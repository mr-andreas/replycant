---
sidebar_position: 5
---

# Back up your library

Keep a full copy of your photos on another computer, so you still have them if the server is lost. A clone that includes the photos holds the whole library, and a scheduled pull keeps it current.

You need:

- `git`, `git-lfs`, and `git-replycant` installed on the backup computer, as in [Clone your library](./clone-your-library.md)
- an encrypted disk with free space for about twice the size of your library
- the iPhone you connected in [Start a server](./start-a-server.md)

## Set up the backup

1. In your home folder, clone the library with the photos:

   ```bash
   cd ~
   git-replycant clone backup
   ```

2. Open the address it prints in a browser. On the iPhone, tap **Settings**, then **Link a New Device**, and scan the QR code.

   The clone downloads the photos and finishes:

   ```text
   Joined the tailnet. Waiting for repository authorization...
   Authorization confirmed. Proceeding with clone.
   ...
   Clone complete and filters configured in /home/you/backup
   ```

3. Check that a pull works:

   ```bash
   cd ~/backup && git pull --ff-only
   ```

   ```text
   Already up to date.
   ```

4. Run `crontab -e` and add these two lines to pull every hour. Cron starts with a short `PATH`, so the first line lets it find `git-replycant` and `git-lfs`.

   ```text
   PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
   0 * * * * cd ~/backup && git pull --ff-only
   ```

## What the backup holds

![What a backup clone stores](./back-up-your-library/backup-contents.drawio.svg)

The `.git` folder holds the full history and the encrypted photos. The rest of the folder holds the same photos decrypted, which is why the backup needs an encrypted disk and about twice the space of the library.
