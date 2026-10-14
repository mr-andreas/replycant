---
sidebar_position: 3
---

# Clone your library

Clone the library to a computer so you can import photos into it from the command line. The `git-replycant` tool links the computer to your library as a new device and creates a local Git copy of the library.

You need:

- `git` and `git-lfs` (Git Large File Storage, which Git uses for the photos)
- the iPhone you connected in [Start a server](./start-a-server.md)

## Clone without the photos

1. Download the `git-replycant` archive for your system from the [latest release](https://github.com/mr-andreas/replycant/releases/latest). In the folder that holds the download, install it:

   ```bash
   sudo tar -xzf git-replycant-*.tar.gz -C /usr/local/bin
   ```

2. Clone the library into `my-library`:

   ```bash
   git-replycant clone --no-lfs my-library
   ```

   `--no-lfs` leaves the photos on the server, which is the setup the [importer](./import-media.md) expects. The command prints an address and waits:

   ```text
   Generated new local identity in /home/you/my-library/.git/replycant
   Open http://127.0.0.1:54321 to view the pairing QR code.
   Waiting for a paired device to approve this one...
   ```

3. Open the address it prints in a browser. On the iPhone, tap **Settings**, then **Link a New Device**, and scan the QR code.

   The clone continues once the iPhone approves it:

   ```text
   Joined the tailnet. Waiting for repository authorization...
   Authorization confirmed. Proceeding with clone.
   ...
   Clone complete and filters configured in /home/you/my-library
   ```

## Next steps

[Import photos and videos](./import-media.md) into the clone.
