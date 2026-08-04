# Thumbnails

The iOS app generates and stores thumbnails to enable fast grid rendering without loading full-resolution originals. Thumbnails now use a single `ThumbnailSet` manifest per original.

## Why Pre-Generated Thumbnails

Loading original media files (2-5 MB for photos, hundreds of MB for videos) would cause:

- Poor UI performance
- Excessive bandwidth usage
- Slow scrolling in timeline views

Pre-generated thumbnails provide 200-300x size reduction for instant grid loading.

## Thumbnail Sizes

Three thumbnail variants are generated for each media item:

| Size | Target | Use Case |
|------|--------|----------|
| 150×150 | Square crop | Timeline grid (3-column layout) |
| 225×225 | Square crop | Retina displays, larger grids |
| 1024 | Longest edge | Preview mode, detail views |

All thumbnails use JPEG format with 0.8 compression quality.

## Storage Architecture

### Manifest Location

One manifest per original:

```
manifests/{device-space}/media.replycant.com/v1alpha1/ThumbnailSet/{set-name}.yaml
```

### Binary Location

One pointer file per thumbnail entry:

```
binary/{device-space}/media.replycant.com/v1alpha1/ThumbnailSet/{entry-name}
```

### Naming Convention

- Set name: `{original-name}-thumbs`
- Entry names: `{original-name}-thumb-{size}`

**Examples:**
- Set: `e88f3b2a-1234-photo-thumbs`
- Entries:
  - `e88f3b2a-1234-photo-thumb-150x150`
  - `e88f3b2a-1234-photo-thumb-225x225`
  - `e88f3b2a-1234-photo-thumb-1024`

## ThumbnailSet Manifest

```yaml
apiVersion: media.replycant.com/v1alpha1
kind: ThumbnailSet
metadata:
  name: e88f3b2a-1234-photo-thumbs
  deviceSpace: iphone-14-abc123
spec:
  originalRef: iphone-14-abc123/media.replycant.com/v1alpha1/Original/e88f3b2a-1234-photo
  thumbnails:
    - name: e88f3b2a-1234-photo-thumb-150x150
      sha256: b4f9d82c2e5a6f78901bc23de45fg6789012bcd34efg56789012345678901bcd
      width: 150
      height: 150
      filesize: 8192
    - name: e88f3b2a-1234-photo-thumb-225x225
      sha256: d9e1a3b0c4d95f7412aa6f90ab12cd34ef5678901abc23def456789012345678
      width: 225
      height: 225
      filesize: 15360
    - name: e88f3b2a-1234-photo-thumb-1024
      sha256: f2ab9c72d55aa0189c3ef0a4bc567def8901abc23def45678901234567890abc
      width: 1024
      height: 768
      filesize: 102400
status: {}
```

## Resolving Binary Paths by Resolution

Given a `ThumbnailSet` manifest:

1. Select the target `spec.thumbnails[]` entry by resolution (`width`/`height`).
2. Build the binary pointer path:

```
binary/{metadata.deviceSpace}/{apiVersion}/ThumbnailSet/{entry.name}
```

Example for the `225x225` entry above:

```
binary/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/e88f3b2a-1234-photo-thumb-225x225
```

## Generation Process

### For Photos

1. Request image from `PHImageManager` with target size
2. Configure high-quality delivery with exact resize
3. Extract `CGImage` from resulting `UIImage`
4. Convert to JPEG data with 0.8 compression
5. Calculate SHA-256 hash per entry
6. Upload each entry to LFS
7. Create one `ThumbnailSet` manifest with all entries
8. Add pointers + manifest to commit

### For Videos

1. Request `AVAsset` from `PHImageManager`
2. Create `AVAssetImageGenerator` with target size
3. Extract frame from video midpoint (`duration / 2`)
4. Apply preferred track transform for orientation
5. Resize to target maintaining aspect ratio
6. Convert to JPEG and complete upload flow

## Atomic Commits

All thumbnails are committed together with their original in a single atomic commit:

| Files per Media Item |
|---------------------|
| 1 Original LFS pointer |
| 1 Original manifest |
| 3 Thumbnail LFS pointers |
| 1 ThumbnailSet manifest |
| **Total: 6 files** |

## Implementation

| File | Purpose |
|------|---------|
| `ThumbnailSetManifest.swift` | ThumbnailSet model and serialization |
| `PhotoLibraryManager.swift` | Thumbnail generation methods |
| `PhotoSyncManager.swift` | Atomic commit coordination |
| `TimelineView.swift` | Thumbnail loading and display |
| `ManifestDatabase.swift` | SQLite cache, pagination, and thumbnail-set lookup |
