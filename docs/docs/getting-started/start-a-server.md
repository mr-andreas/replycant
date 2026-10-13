---
sidebar_position: 2
---

# Start a server

The server stores the library. The iOS app creates the library and links the first device.

## 1. Start the server

```bash
$ curl -fsSL -o docker-compose.yaml \
    https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml
$ docker compose up -d
[+] Running 10/10
 ✔ Container replycant-gitd-1        Started
 ✔ Container replycant-decryptd-1    Started
 ...
```

## 2. Install the iOS app

[iOS app on the App Store](https://apps.apple.com/se/app/replycant/id6760653798)

## 3. Create the library

Open `http://localhost:8080`. In the app, tap **Create a new library** and scan the QR code.

On a server with no browser, open `http://<server>:8080` from another computer on the same network.

## Desktop app

Download the desktop app from the [latest release](https://github.com/mr-andreas/replycant/releases/latest): a `.dmg` on macOS, an `.AppImage` or `.deb` on Linux, or the Windows installer.

Enter a device name and click **Generate keypair**. On the iPhone, open **Settings**, **Link a New Device**, and scan the code.
