# Git LFS

The iOS app implements Git Large File Storage (LFS) manually to efficiently handle binary files like photos and videos. libgit2 does not include native LFS support, so the LFS protocol is implemented directly using HTTP operations.

## Why Manual Implementation

| Option | Evaluation |
|--------|------------|
| Separate LFS library | Adds external dependency |
| Manual implementation | Full control, no dependencies |
| Avoid LFS entirely | Not feasible for large media files |

Manual implementation was chosen for full control over the LFS workflow and to avoid additional dependencies.

## Module Boundary

`GitLFS` in LibGit2 speaks the LFS batch API and moves opaque bytes.
It does not encrypt, decrypt, or interpret replycant pointer fields.

GitDB owns encryption:

- `EncryptedLFSPointer` renders and parses `x-replycant-kek-epoch` and `x-replycant-wrapped-dek`
- `EncryptedLFS.uploadEncrypted` supplies an encrypting body stream to LibGit2's streamed PUT
- `EncryptedLFS.loadEncryptedLFSData` downloads ciphertext and unwraps the DEK locally

## LFS Pointer Files

Instead of storing large binaries in Git, LFS uses small pointer files.
LibGit2's `LFSPointer` is the three spec lines only:

```
version https://git-lfs.github.com/spec/v1
oid sha256:a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
size 4521890
```

GitDB writes two extra lines on encrypted objects so clients can unwrap
the per-object DEK without a server-held key.

### Pointer Fields

| Field | Owner | Description |
|-------|-------|-------------|
| `version` | LibGit2 | LFS specification version URL |
| `oid` | LibGit2 | Object ID: `sha256:` prefix + 64-character hex hash |
| `size` | LibGit2 | File size in bytes |
| `x-replycant-kek-epoch` | GitDB | Epoch used to wrap the per-object DEK |
| `x-replycant-wrapped-dek` | GitDB | Base64 AES-GCM wrap of the object DEK |

## Upload Flow

1. **Hash Content**: Calculate SHA-256 of the binary data
2. **Check Existence**: Query LFS server if object already exists
3. **Upload Binary**: POST/PUT binary data to LFS server
4. **Create Pointer**: Generate pointer file content
5. **Commit Pointer**: Add pointer file to Git repository via libgit2

### Batch API Request

Before uploading, the app queries the LFS Batch API:

```http
POST /lfs/objects/batch
Content-Type: application/vnd.git-lfs+json

{
  "operation": "upload",
  "transfers": ["basic"],
  "objects": [
    {
      "oid": "a3f8c92b1e4d...",
      "size": 4521890
    }
  ]
}
```

### Batch API Response

```json
{
  "objects": [
    {
      "oid": "a3f8c92b1e4d...",
      "size": 4521890,
      "actions": {
        "upload": {
          "href": "https://lfs.example.com/objects/a3f8c92b...",
          "header": {
            "Authorization": "Bearer token..."
          }
        }
      }
    }
  ]
}
```

## Download Flow

1. **Read Pointer**: Parse pointer file from Git repository
2. **Query Batch API**: Request download URL for the OID
3. **Download Binary**: GET binary data from provided URL
4. **Verify Hash**: Confirm SHA-256 matches the OID
5. **Store Locally**: Cache binary for offline access

### Download Request

```http
POST /lfs/objects/batch
Content-Type: application/vnd.git-lfs+json

{
  "operation": "download",
  "transfers": ["basic"],
  "objects": [
    {
      "oid": "a3f8c92b1e4d...",
      "size": 4521890
    }
  ]
}
```

## Implementation

Vanilla transport lives in LibGit2's `GitLFS.swift`. Encrypted upload
and download wrap that transport from GitDB:

```swift
// LibGit2: opaque batch upload/download and streamed PUT
func uploadData(_ data: Data) async throws -> LFSPointer
func downloadData(oid: String, size: Int64) async throws -> Data
func uploadStream(oid: String, size: Int64, makeBody: () throws -> InputStream) async throws -> LFSPointer

// GitDB: encrypt on the way out, unwrap DEK on the way in
EncryptedLFS.uploadEncrypted(fileURL:dek:oid:size:lfsClient:)
EncryptedLFS.loadEncryptedLFSData(from:repository:lfsClient:)
EncryptedLFSPointer.parse(_:)
```

## Authentication

LFS operations use the same mTLS authentication as Git operations. The `URLSession` is configured with the device's client certificate for all LFS requests.

## Error Handling

| Error | Handling |
|-------|----------|
| Object exists | Skip upload, use existing OID |
| Upload failed | Retry with exponential backoff |
| Hash mismatch | Reject download, report corruption |
| Network error | Queue for retry when online |

## Advantages

- **Full control**: Optimize for specific use case
- **No dependencies**: No additional third-party libraries
- **Protocol knowledge**: Better debugging and error handling
- **Selective features**: Implement only what's needed

## Trade-offs

- **Maintenance burden**: Must maintain LFS protocol logic
- **HTTP complexity**: Handle all HTTP edge cases
- **Pointer format**: Must follow LFS specification exactly
- **Testing overhead**: Additional testing for LFS functionality
