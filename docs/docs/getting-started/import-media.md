---
sidebar_position: 4
---

# Import photos and videos

`replycant-importer` reads a folder of photos and videos, encrypts each file, uploads it, and commits it to the library. Use it to load media you already have. Photos taken on a paired iPhone sync on their own.

## Before you start

- A repository cloned with `git-replycant clone --no-lfs`, as described in [Clone your library](./clone-your-library.md). The importer rejects a clone that downloads media itself.
- `ffmpeg` and `ffprobe` on your `PATH`, used to read video duration and to build thumbnails.
- The `replycant-importer` binary from the [latest GitHub Release](https://github.com/mr-andreas/replycant/releases/latest), placed on your `PATH` the same way as `git-replycant`.

## Run the import

```bash
replycant-importer my-import-repo ~/Pictures/to-import family-archive --push-every 100
```

The three arguments are the clone, the folder to read (including its subfolders), and a device space name. A device space is the namespace these files are stored under. Pick a short name for the source, such as `family-archive`. It keeps this batch distinct from photos synced from a phone.

`--push-every 100` pushes after every 100 commits, so a long import reaches the server while it is still running. Use a smaller number to push more often. Leave the flag off and the commits stay in the clone until you run `git push` there yourself.

`-v` prints git and upload progress. `--workers` sets how many files are processed at once. The default is one worker per CPU.

Imported photos and videos show up on the iPhone and the desktop app at their next sync.

## Stopping an import

Press Ctrl+C once to stop taking new files. Work already in flight is cancelled, and partial files from the cancelled item are removed. Commits that already finished are pushed when `--push-every` is set.

Press Ctrl+C a second time to skip that final push. Those commits stay in the clone until you run `git push`. A third Ctrl+C stops the process immediately.

[Importing media](../cli/importing.md) describes how this path differs from the apps.
