---
sidebar_position: 4
---

# Import photos and videos

Add an existing folder of photos and videos to your library, such as an old camera archive. The `replycant-importer` tool commits the files to a clone of your library, and you push them to the server.

You need:

- the clone from [Clone your library](./clone-your-library.md)
- `ffmpeg`, which includes the `ffprobe` tool the importer also uses

## Import a folder

1. Download the `replycant-importer` archive for your system from the [latest release](https://github.com/mr-andreas/replycant/releases/latest). In the folder that holds the download, install it:

   ```bash
   sudo tar -xzf replycant-importer-*.tar.gz -C /usr/local/bin
   ```

2. From the folder that contains `my-library`, import your photos. Replace `~/Pictures/holiday` with your own folder. The last argument, `holiday`, is a name for this batch.

   ```bash
   replycant-importer my-library ~/Pictures/holiday holiday
   ```

   The importer checks its tools, scans the folder, and reports each file:

   ```text
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

3. Push the imported files to the server:

   ```bash
   git -C my-library push
   ```

   ```text
   Enumerating objects: 18, done.
   Counting objects: 100% (18/18), done.
   ...
   To replycant::https://gitd.replycant.internal:8443
      a1b2c3d..e4f5a6b  main -> main
   ```

Your photos now show up in the apps.
