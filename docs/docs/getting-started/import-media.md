---
sidebar_position: 4
---

# Import photos and videos

Install `ffmpeg`, and use the clone from [Clone your library](./clone-your-library.md). The last argument is a name for this batch.

```bash
$ replycant-importer my-library ~/Pictures/holiday holiday
boot: validating repository /home/you/my-library
boot: repository ok
boot: source directory /home/you/Pictures/holiday
boot: checking required tools
boot: tools ready (ffmpeg, ffprobe)
boot: loading existing manifests
boot: loaded 0 known sha256 values
boot: scanning source files
boot: found 3 source files
commit: 3 file(s) in 4.2s
[1/3] IMG_0001.jpg imported
[2/3] IMG_0002.jpg imported
[3/3] VID_0003.mp4 imported
```

```bash
$ git -C my-library push
Enumerating objects: 18, done.
Counting objects: 100% (18/18), done.
...
To replycant::https://gitd.replycant.internal:8443
   a1b2c3d..e4f5a6b  main -> main
```

The photos show up in the apps.
