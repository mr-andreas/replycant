# Media Storage

Original media files (photos and videos) are stored using a two-component architecture: a YAML manifest for metadata and a Git LFS pointer for the binary content.

## Architecture Overview

Each media file consists of:

1. **Original Manifest** - YAML file with all metadata
2. **LFS Pointer** - Small text file pointing to the binary in LFS storage

This separation keeps the Git repository small while preserving complete metadata for search and organization.

## Original Manifest

### Storage Location

```
manifests/{device-space}/media.replycant.com/v1alpha1/Original/{name[0:2]}/{name[2:4]}/{name[4:]}.yaml
```

### Manifest Structure

```yaml
apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: e88f3b2a-1234-5678-9abc-def012345678-l0-001
  deviceSpace: iphone-14-abc123
spec:
  id: E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001
  sha256: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
  path: /var/mobile/Media/DCIM/100APPLE/IMG_1234.JPG
  filesize: 4521890
  mediaType: photo
  width: 4032
  height: 3024
  creationDate: 2025-10-19T14:23:45Z
  modificationDate: 2025-10-19T14:23:45Z
  duration: null
  mimeType: image/jpeg
  location:
    latitude: 37.7749
    longitude: -122.4194
    altitude: 10.5
  isFavorite: false
  isHidden: false
  burstIdentifier: null
status: {}
```

### Field Reference

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Original identifier from source photo library |
| `sha256` | string | SHA-256 hash of binary content for integrity verification |
| `path` | string | Original absolute file path when uploaded |
| `filesize` | integer | Size in bytes |
| `mediaType` | enum | `photo` or `video` |
| `width` / `height` | integer | Pixel dimensions |
| `creationDate` | ISO 8601 | When the media was captured |
| `modificationDate` | ISO 8601 | When the media was last modified |
| `duration` | number | Video duration in seconds (null for photos) |
| `mimeType` | string | MIME type (e.g., `image/jpeg`, `video/mp4`) |
| `location` | object | GPS coordinates where captured (optional) |
| `isFavorite` | boolean | User favorite flag |
| `isHidden` | boolean | User hidden flag |
| `burstIdentifier` | string | Burst sequence identifier (optional) |

## Binary LFS Storage

### Storage Location

```
binary/{device-space}/media.replycant.com/v1alpha1/Original/{name[0:2]}/{name[2:4]}/{name[4:]}
```

### LFS Pointer Format

The Git repository contains a small pointer file (not the actual binary):

```
version https://git-lfs.github.com/spec/v1
oid sha256:a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
size 4521890
```

The actual binary data is stored on the LFS server and fetched on demand.

## Upload Flow

1. **Hash Calculation**: Compute SHA-256 of the binary content
2. **Binary Upload**: Upload binary data to LFS server via HTTP
3. **Pointer Creation**: Generate LFS pointer file with OID and size
4. **Manifest Creation**: Create Original manifest with all metadata
5. **Atomic Commit**: Commit both pointer and manifest together

### Commit Message Format

```
Add photo: IMG_1234.JPG

Captured: 2025-10-19T14:23:45Z
Size: 4521890 bytes
LFS OID: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
```

## Content Addressing

The SHA-256 hash in the manifest provides content addressing:

- **Deduplication**: Same binary content produces same hash across devices
- **Integrity**: Verify downloaded content matches expected hash
- **Linking**: Hash connects manifest to specific binary version

## Storage Efficiency

For a typical 4.5 MB photo:

| Component | Size |
|-----------|------|
| Binary (in LFS) | 4.5 MB |
| LFS Pointer (in Git) | ~100 bytes |
| Manifest (in Git) | ~500-800 bytes |
| **Total Git impact** | ~600-900 bytes |

This represents a ~5000x reduction in Git repository size compared to storing binaries directly.

## Device Space Isolation

Both manifests and binaries are organized by device space:

- Each device writes to its own namespace
- Prevents naming conflicts across devices
- Enables device-specific queries
- Supports selective sync by device
