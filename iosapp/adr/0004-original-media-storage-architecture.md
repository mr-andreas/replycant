# ADR-0004: Original Media Storage Architecture

## Status

Accepted

## Context

The application needs to store user photos and videos in a Git repository with full version control, device synchronization, and efficient handling of large binary files. This must preserve all media metadata (dimensions, dates, location, etc.) while avoiding repository bloat from large binary objects.

This decision builds upon:
- ADR-0002: Manual Git LFS implementation
- ADR-0003: Manifest-based Git database

The storage solution must:
- Preserve complete media metadata for search and organization
- Handle large binary files efficiently without bloating the Git repository
- Support distributed synchronization across multiple devices
- Enable version control and audit trails for all changes
- Provide device-specific namespacing to prevent conflicts

## Decision

We implement a two-component storage architecture for original media files:

### 1. Original Manifest (Metadata)

Each media file has a corresponding YAML manifest that stores all metadata as a Kubernetes-style resource.

**Storage Location:**
```
manifests/{device-space}/media.replycant.com/v1alpha1/Original/{normalized-name}.yaml
```

**Manifest Structure:**
```yaml
apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: {normalized-name}
  deviceSpace: {device-space-identifier}
spec:
  id: {original-asset-id}
  sha256: {sha256-hash-of-binary}
  path: {original-absolute-path}
  filesize: {size-in-bytes}
  mediaType: {photo|video}
  width: {width-pixels}
  height: {height-pixels}
  creationDate: {iso8601-timestamp}
  modificationDate: {iso8601-timestamp}
  duration: {seconds-for-video}
  mimeType: {media-mime-type}
  location:
    latitude: {decimal-degrees}
    longitude: {decimal-degrees}
    altitude: {meters}
  isFavorite: {boolean}
  isHidden: {boolean}
  burstIdentifier: {burst-sequence-id}
status: {}
```

**Field Descriptions:**

- `id`: Original unique identifier from the source photo library (e.g., PHAsset.localIdentifier)
- `sha256`: SHA-256 hash of the complete binary file content, used for integrity verification and deduplication
- `path`: Absolute file path where the media originally resided when uploaded (e.g., "/var/mobile/Media/DCIM/100APPLE/IMG_1234.JPG")
- `filesize`: Size of the binary file in bytes
- `mediaType`: Either "photo" or "video"
- `width` / `height`: Pixel dimensions of the media
- `creationDate`: ISO 8601 timestamp when the media was originally captured/created
- `modificationDate`: ISO 8601 timestamp when the media was last modified
- `duration`: Video duration in seconds (null for photos)
- `mimeType`: MIME type of the media (e.g., "image/jpeg", "video/mp4")
- `location`: Optional GPS coordinates where the media was captured
- `isFavorite`: User favorite flag from photo library
- `isHidden`: User hidden flag from photo library
- `burstIdentifier`: Identifier linking photos in a burst sequence

### 2. Binary LFS Object (Media Content)

The actual media binary is stored using Git Large File Storage (LFS) through a pointer file.

**Storage Location:**
```
binary/{device-space}/media.replycant.com/v1alpha1/Original/{normalized-name}
```

**LFS Pointer File Format:**
```
version https://git-lfs.github.com/spec/v1
oid sha256:{64-character-hex-sha256}
size {bytes}
```

**Storage Flow:**

1. **Binary Upload**: The media binary data is uploaded directly to the LFS server via HTTP using the manual LFS implementation (ADR-0002)

2. **Pointer Creation**: A small LFS pointer file is created containing:
   - LFS specification version
   - SHA-256 hash (OID) of the binary content
   - Size of the binary in bytes

3. **Repository Commit**: The LFS pointer file (not the binary) is committed to the Git repository through libgit2

4. **Manifest Creation**: The Original manifest is generated with complete metadata and committed alongside the pointer file

5. **Atomic Commit**: Both the LFS pointer and manifest are committed together in a single Git commit with a descriptive message:
   ```
   Add photo: IMG_1234.JPG
   
   Captured: 2025-10-19T14:23:45Z
   Size: 4521890 bytes
   LFS OID: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
   SHA256: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
   ```

### Naming Convention

Object names (used in both manifest and binary paths) follow the naming convention from ADR-0003:

**Pattern:** `[a-z][a-z0-9-]{0,252}`

**Normalization Process:**
1. Convert original asset ID to lowercase
2. Replace all non-alphanumeric characters (except hyphens) with hyphens
3. Collapse consecutive hyphens into single hyphens
4. Remove leading/trailing hyphens
5. If name doesn't start with a letter, prepend "a"
6. Truncate to 253 characters maximum

**Example:**
- Original ID: `E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001`
- Normalized: `e88f3b2a-1234-5678-9abc-def012345678-l0-001`

### Device Space Isolation

Both manifests and binaries are organized by device space:
- Device space identifier is generated per-device (currently using vendor identifier)
- All objects are namespaced under their device space
- Prevents naming conflicts when multiple devices sync to same repository
- Enables device-specific queries and operations

### Content Addressing

The SHA-256 hash in the manifest provides content addressing:
- Same binary content always produces same hash
- Enables deduplication detection (same photo on multiple devices)
- Provides integrity verification
- Links manifest to specific binary version

## Consequences

### Positive

- **Separation of Concerns**: Metadata (manifest) and content (binary) are independently versioned and managed
- **Efficient Storage**: Large binaries stored in LFS don't bloat Git repository history
- **Rich Metadata**: Complete preservation of all media attributes for search, organization, and display
- **Human Readable**: Manifest files are YAML and can be inspected, edited, or debugged manually
- **Version Control**: All metadata changes tracked in Git history with full audit trail
- **Device Isolation**: Device space namespacing prevents conflicts in multi-device scenarios
- **Content Integrity**: SHA-256 hashing enables verification and deduplication detection
- **Atomic Updates**: Pointer and manifest committed together ensures consistency
- **Extensible Schema**: Can add new fields to spec without breaking existing code
- **Distributed Sync**: Standard Git push/pull operations synchronize both manifests and LFS objects

### Negative

- **Two-Part Retrieval**: Accessing media requires reading both manifest and fetching LFS binary
- **Storage Overhead**: Each media file requires both a manifest file and an LFS pointer file in the repository
- **Complexity**: Must maintain consistency between manifest metadata and binary content
- **LFS Dependency**: Requires properly configured LFS server for binary storage
- **Network Cost**: Initial sync must download both manifests and LFS binaries
- **Potential Desync**: Manifest and binary could theoretically get out of sync if operations fail partway

### Implementation Requirements

- Original manifests must be created in `iosapp/Models/OriginalManifest.swift` following the Codable structure
- Serialization to/from YAML handled by `ManifestSerializer` in `iosapp/Models/ManifestSerializer.swift`
- PhotoSyncManager coordinates the upload of both binary (via LFS) and manifest (via Git)
- SHA-256 hashing performed using CryptoKit before upload
- Both files committed atomically using libgit2's commit API
- Manifest cached locally using ManifestCacheManager for offline access

### Storage Efficiency Example

For a 4.5 MB photo:
- **Binary Storage**: 4.5 MB in LFS server (not in Git repo)
- **LFS Pointer**: ~100 bytes in Git repository
- **Manifest**: ~500-800 bytes in Git repository (depends on metadata richness)
- **Total Git Repo Impact**: ~600-900 bytes (vs 4.5 MB without LFS)

### Integration Points

- Integrates with manual LFS implementation (ADR-0002) for binary uploads
- Follows manifest-based database pattern (ADR-0003) for metadata structure
- Device space from DeviceIdentifierManager provides namespacing
- ManifestCacheManager provides local caching layer for offline access

### Future Considerations

- Manifest versioning (apiVersion) enables schema evolution
- Status field reserved for future operational state tracking
- Could implement manifest indexing for efficient queries
- Could add garbage collection for orphaned LFS objects

