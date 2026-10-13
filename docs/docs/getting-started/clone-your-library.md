---
sidebar_position: 3
---

# Clone your library

You need `git` and `git-lfs`. Download the `git-replycant` archive for your system from the [latest release](https://github.com/mr-andreas/replycant/releases/latest) and install it:

```bash
$ sudo tar -xzf git-replycant-*.tar.gz -C /usr/local/bin
```

`--no-lfs` skips downloading the photos. The [importer](./import-media.md) needs that. A [backup](./back-up-your-library.md) leaves the flag off.

```bash
$ git-replycant clone --no-lfs my-library
Generated new local identity in /home/you/my-library/.git/replycant
Open http://127.0.0.1:54321 to view the pairing QR code.
Waiting for a paired device to approve this one...
Joined the tailnet. Waiting for repository authorization...
Authorization confirmed. Proceeding with clone.
From replycant::https://gitd.replycant.internal:8443
 * [new branch]      main       -> origin/main
...
Clone complete and filters configured in /home/you/my-library
```

Open the address it prints and scan the QR code from the iPhone: **Settings**, **Link a New Device**. The clone continues once the phone approves.
