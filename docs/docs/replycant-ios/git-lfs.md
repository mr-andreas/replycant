# Git LFS

The iOS app implements Git Large File Storage (LFS) manually to efficiently handle binary files like photos and videos. libgit2 does not include native LFS support, so the LFS protocol is implemented directly using HTTP operations.

## Why Manual Implementation

| Option | Evaluation |
|--------|------------|
| Separate LFS library | Adds external dependency |
| Manual implementation | Full control, no dependencies |
| Avoid LFS entirely | Not feasible for large media files |

Manual implementation was chosen for full control over the LFS workflow and to avoid additional dependencies.

## LFS Pointer Files

Instead of storing large binaries in Git, LFS uses small pointer files:

```
version https://git-lfs.github.com/spec/v1
oid sha256:a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
size 4521890
```

### Pointer Fields

| Field | Description |
|-------|-------------|
| `version` | LFS specification version URL |
| `oid` | Object ID: `sha256:` prefix + 64-character hex hash |
| `size` | File size in bytes |

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

The LFS implementation is in `GitLFS.swift`:

```swift
// Upload binary to LFS server
func uploadObject(data: Data, to url: URL) async throws -> LFSObject

// Download binary from LFS server  
func downloadObject(oid: String, size: Int, from url: URL) async throws -> Data

// Parse pointer file content
func parsePointer(_ content: String) -> LFSPointer?

// Generate pointer file content
func createPointer(oid: String, size: Int) -> String
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
