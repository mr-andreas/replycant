---
sidebar_position: 2
---

# Start a server

Run your own Replycant server and create your photo library on it with the iPhone app. The server stores the library, and the iPhone becomes its first device.

You need:

- a computer with Docker and Docker Compose, to run the server
- an iPhone

## Create your library

1. Download the Compose file and start the server:

   ```bash
   mkdir replycant && cd replycant
   curl -fsSL -o docker-compose.yaml \
     https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml
   docker compose up -d
   ```

   Compose reports each container as it starts:

   ```text
   [+] Running 10/10
    ✔ Container replycant-gitd-1        Started
    ✔ Container replycant-decryptd-1    Started
    ...
   ```

2. Install [Replycant from the App Store](https://apps.apple.com/se/app/replycant/id6760653798) on your iPhone.
3. Open `http://localhost:8080` in a browser on the server. If the server has no browser, open `http://<server-address>:8080` from another computer on the same network, with the server's IP address or hostname in place of `<server-address>`.
4. In the app, tap **Create a new library** and scan the QR code on the page.

Your library is ready, and the iPhone is connected to it.

## Link the desktop app

To browse your library on a Mac, Windows, or Linux computer:

1. Download the desktop app from the [latest release](https://github.com/mr-andreas/replycant/releases/latest): the `.dmg` on macOS, the `.AppImage` or `.deb` on Linux, or the Windows installer.
2. Open the app, enter a name for this computer, and click **Generate keypair**.
3. On the iPhone, tap **Settings**, then **Link a New Device**, and scan the QR code the desktop app shows.

## Next steps

- To add photos from a computer, [clone your library](./clone-your-library.md) and then [import photos and videos](./import-media.md).
- To keep a copy of your photos on another computer, [back up your library](./back-up-your-library.md).
