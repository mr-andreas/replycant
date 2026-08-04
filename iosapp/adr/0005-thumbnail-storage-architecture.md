# ADR-0005: Thumbnail Storage Architecture

## Status

Accepted

## Context

The application needs to display media efficiently in grid views and timelines without loading full-resolution originals. Loading original media files (which can be several megabytes for photos and hundreds of megabytes for videos) would cause poor UI performance, excessive bandwidth usage, and slow scrolling experiences.

This decision builds upon:
- ADR-0002: Manual Git LFS implementation
- ADR-0003: Manifest-based Git database
- ADR-0004: Original Media Storage Architecture

The thumbnail solution must:
- Enable fast grid/list view rendering without downloading full originals
- Support multiple thumbnail sizes for different UI contexts
- Work for both photos and videos
- Maintain linkage to original media
- Follow the same storage patterns as originals for consistency
- Be generated once and stored permanently to avoid repeated processing

## Decision

We implement a parallel storage architecture for thumbnails that mirrors the original media structure.

### 1. Thumbnail Manifest (Metadata)

Each thumbnail has a corresponding YAML manifest that stores metadata and links back to its original.

**Storage Location:**
```
manifests/{device-space}/media.replycant.com/v1alpha1/thumbnail/{thumbnail-name}.yaml
```

**Manifest Structure:**
```yaml
apiVersion: media.replycant.com/v1alpha1
kind: Thumbnail
metadata:
  name: {thumbnail-name}
  deviceSpace: {device-space-identifier}
spec:
  id: {thumbnail-id}
  sha256: {sha256-hash-of-thumbnail}
  resolution:
    width: {width-pixels}
    height: {height-pixels}
  filesize: {size-in-bytes}
  originalRef: {device-space}/media.replycant.com/v1alpha1/Original/{original-name}
status: {}
```

**Field Descriptions:**

- `id`: Unique identifier for the thumbnail (format: `{original-asset-id}-thumb-{size}`)
- `sha256`: SHA-256 hash of the thumbnail binary content
- `resolution`: Exact pixel dimensions of the generated thumbnail
- `filesize`: Size of the thumbnail binary in bytes
- `originalRef`: Full reference path to the Original manifest this thumbnail derives from

### 2. Binary LFS Object (Thumbnail Content)

The actual thumbnail image is stored using Git LFS through a pointer file.

**Storage Location:**
```
binary/{device-space}/media.replycant.com/v1alpha1/thumbnail/{thumbnail-name}
```

**LFS Pointer File Format:**
```
version https://git-lfs.github.com/spec/v1
oid sha256:{64-character-hex-sha256}
size {bytes}
```

### 3. Thumbnail Sizes

Three thumbnail variants are generated for each media item:

**150x150**: Small grid thumbnail for dense layouts
- Target size: 150x150 pixels
- Aspect ratio: Maintained (actual size may vary slightly)
- Quality: JPEG at 0.8 compression
- Use case: Timeline grid view (3-column layout)

**225x225**: Medium grid thumbnail for larger displays
- Target size: 225x225 pixels
- Aspect ratio: Maintained (actual size may vary slightly)
- Quality: JPEG at 0.8 compression
- Use case: Retina/3x displays, larger grid layouts

**1024 (longest edge)**: Preview thumbnail for detail views
- Target size: 1024 pixels on longest edge
- Aspect ratio: Fully maintained
- Quality: JPEG at 0.8 compression
- Use case: Preview mode, medium-res display before loading original

### 4. Naming Convention

Thumbnail names follow the pattern:
```
{normalized-original-name}-thumb-{size}
```

**Examples:**
- `e88f3b2a-1234-5678-9abc-def012345678-l0-001-thumb-150x150`
- `e88f3b2a-1234-5678-9abc-def012345678-l0-001-thumb-225x225`
- `e88f3b2a-1234-5678-9abc-def012345678-l0-001-thumb-1024`

The normalized-original-name follows the same normalization rules as Original manifests (ADR-0004).

### 5. Generation Process

**For Photos:**
1. Request image from PHImageManager with target size and aspect fill
2. Configure high quality delivery mode with exact resize
3. Extract CGImage from resulting UIImage
4. Convert to JPEG data with 0.8 compression quality
5. Calculate SHA-256 hash of JPEG data
6. Upload to LFS server
7. Create thumbnail manifest with resolution and hash
8. Add both LFS pointer and manifest to commit

**For Videos:**
1. Request AVAsset from PHImageManager
2. Create AVAssetImageGenerator with target size
3. Extract frame from middle of video (duration / 2)
4. Apply preferred track transform for correct orientation
5. Resize to exact target size maintaining aspect ratio
6. Convert to JPEG data with 0.8 compression quality
7. Calculate SHA-256 hash of JPEG data
8. Upload to LFS server
9. Create thumbnail manifest with resolution and hash
10. Add both LFS pointer and manifest to commit

### 6. Atomic Commit Strategy

All thumbnails are generated and committed together with their original media in a single atomic commit:

**Commit Contents:**
- 1 Original LFS pointer
- 1 Original manifest
- 3 Thumbnail LFS pointers (150x150, 225x225, 1024)
- 3 Thumbnail manifests
- **Total: 8 files per media item**

**Commit Message Format:**
```
Add photo: IMG_1234.JPG

Captured: 2025-10-19T14:23:45Z
Size: 4521890 bytes
LFS OID: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
SHA256: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
```

### 7. Loading Strategy

**Timeline Grid View:**
1. Load thumbnail manifest from cache
2. Use 150x150 thumbnail path from manifest metadata
3. Fetch thumbnail binary from LFS
4. Display in grid cell
5. **Fallback**: If thumbnail unavailable and media is photo, load original

**Full-Screen View:**
1. Load original binary from LFS (not thumbnail)
2. Display full resolution for zoom and pan
3. Thumbnails not used in full-screen mode

### 8. OriginalRef Linkage

The `originalRef` field provides bidirectional linking:

**Format:** `{device-space}/media.replycant.com/v1alpha1/Original/{original-name}`

**Example:** `iphone-14-pro-0123456789/media.replycant.com/v1alpha1/Original/e88f3b2a-1234-5678-9abc-def012345678-l0-001`

This enables:
- Finding all thumbnails for a given original
- Navigating from thumbnail to original metadata
- Cleanup operations (delete original + all thumbnails)
- Integrity verification (ensure thumbnail matches original)

## Consequences

### Positive

- **Fast Grid Rendering**: Small thumbnails load quickly without network bottleneck
- **Bandwidth Efficient**: 150x150 thumbnail ~5-15 KB vs original 2-5 MB (200-300x reduction)
- **Responsive Scrolling**: Can load many thumbnails simultaneously without performance impact
- **Multiple Sizes**: Different thumbnail sizes optimized for different UI contexts
- **Video Support**: Videos get static frame thumbnails for efficient preview
- **Consistent Pattern**: Follows same manifest + LFS storage as originals
- **Atomic Uploads**: Original and all thumbnails committed together ensures consistency
- **Cached Locally**: ManifestCacheManager caches thumbnail manifests for offline access
- **Content Integrity**: SHA-256 hash enables verification of thumbnail content
- **Device Isolation**: Device space namespacing prevents conflicts
- **Lazy Generation**: Thumbnails only generated during initial upload, not on-demand
- **Progressive Loading**: Can show thumbnail while original loads in background

### Negative

- **Storage Overhead**: Each media requires 8 files (original + 3 thumbnails with manifests)
- **Upload Time**: Generating and uploading 3 thumbnails per media increases sync duration
- **Duplicate Data**: Same visual content stored at multiple resolutions
- **Failed Thumbnails**: If thumbnail generation fails, sync continues but grid may be slower
- **No Dynamic Sizing**: Cannot request arbitrary thumbnail sizes, limited to 3 presets
- **JPEG Only**: All thumbnails converted to JPEG regardless of original format
- **Fixed Quality**: 0.8 compression quality hardcoded, no user control
- **Generation Cost**: Initial sync processes each image/video 4 times (original + 3 thumbnails)

### Implementation Requirements

- ThumbnailManifest model in `iosapp/Models/ThumbnailManifest.swift`
- Thumbnail generation in `PhotoLibraryManager.generateThumbnail()` and `generateThumbnailLongestEdge()`
- Video thumbnail extraction in `PhotoLibraryManager.generateVideoThumbnail()`
- Atomic commit coordination in `PhotoSyncManager.syncAssets()`
- Thumbnail loading in `TimelineView.ImageLoader`
- Local caching in `ManifestCacheManager`
- LFS upload/download through manual LFS implementation (ADR-0002)

### Storage Efficiency Example

For a typical 4.5 MB photo:
- **Original Storage**: 4.5 MB in LFS
- **150x150 Thumbnail**: ~8 KB in LFS
- **225x225 Thumbnail**: ~15 KB in LFS  
- **1024 Thumbnail**: ~120 KB in LFS
- **Total LFS**: ~4.64 MB
- **Git Repo Impact**: ~2.4 KB (4 pointers + 4 manifests)
- **Overhead**: ~3% increase for 200-300x faster grid loading

### Integration Points

- Integrates with PhotoLibraryManager for image/video processing
- Uses manual LFS implementation (ADR-0002) for binary uploads
- Follows manifest-based database pattern (ADR-0003)
- Extends Original media architecture (ADR-0004)
- Cached by ManifestCacheManager for offline access
- Loaded by TimelineView for grid display
- Referenced by TimelineManager when building timeline items

### Future Considerations

- Could add adaptive thumbnail sizing based on device screen density
- Could implement WebP format for better compression (30-50% smaller)
- Could add progressive JPEG encoding for faster initial display
- Could generate thumbnails on-demand on server side instead of client
- Could implement thumbnail regeneration if quality settings change
- Status field reserved for future operational state (e.g., "generating", "failed")
- Could add blur hash or placeholder color in manifest for instant preview
- Could implement smart cropping for face/subject detection in thumbnails

