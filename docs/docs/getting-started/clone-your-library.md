---
sidebar_position: 3
---

# Clone your library

A clone is a normal Git checkout of the library on a Linux or macOS computer. Importing photos and backing the library up both start here. The two jobs want different clones, so decide which one you are making before you run the command.

## Install the tools

You need `git`, `git-lfs`, and `git-replycant`.

Download the `git-replycant` archive for your system from the [latest GitHub Release](https://github.com/mr-andreas/replycant/releases/latest). The archive contains `git-replycant` and a `git-remote-replycant` symlink to it. Git uses that second name to reach the library, so both have to be on your `PATH`. Extracting the archive straight into a directory on your `PATH` keeps the symlink intact:

```bash
sudo tar -xzf git-replycant-*.tar.gz -C /usr/local/bin
```

## Clone

```bash
git-replycant clone
```

That creates a directory named `replycant` in the current directory. Pass a name to choose another:

```bash
git-replycant clone my-library
```

The command prints a `http://127.0.0.1` address. Open it on the same computer. The page shows a QR code, and it only listens on that computer because the code is an approval request. Approve it from the iPhone: **Settings**, **Link a New Device**, **Scan QR Code**. The same steps are written out in [Approve a new device](./start-a-server.md#approve-a-new-device).

Once the phone approves, the clone fetches the library and checks out the default branch. Later `git fetch`, `git pull`, and `git push` in this directory reuse the connection. It starts when a command needs it and exits after a few idle minutes, so there is no service to leave running.

`--device-name` sets the name this computer uses in the library. Leave it off and the name is `git-replycant`.

## Choose what the clone downloads

A default clone downloads every photo and video and decrypts it into the working tree. That is the clone a [backup](./back-up-your-library.md) uses, and it needs `git-lfs` installed.

A clone for [importing](./import-media.md) skips those downloads. The importer uploads media itself and refuses a clone that is set up to download it:

```bash
git-replycant clone --no-lfs my-import-repo
```

[Cloning repositories](../cli/cloning.md) covers the flags and what the command configures.
