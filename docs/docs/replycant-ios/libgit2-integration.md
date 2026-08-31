# libgit2 Integration

The iOS app uses libgit2 for all Git operations. libgit2 is a portable, pure C implementation of Git core methods provided as a linkable library.

## Why libgit2

Two options were evaluated for native Git support:

| Option | Status |
|--------|--------|
| **libgit2** | Active maintenance, cross-platform, stable C API |
| **Swiftgit2** | Unmaintained, doesn't compile with recent Xcode |

libgit2 was chosen for its reliability and active community support.

## Integration Architecture

LibGit2 is vanilla git: repository open/clone/commit, remotes, and
opaque Git LFS batch upload/download. Replycant encryption, key
epochs, and encrypted pointer metadata live in GitDB.

```
Swift App
    ↓
GitDB (encryption, SQL cache, commit paths)
    ↓
LibGit2 Swift Package (vanilla git + LFS transport)
    ↓
libgit2.xcframework (C library)
    ↓
Git Repository (local filesystem)
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `libgit2.xcframework` | Project root | Compiled C library for iOS |
| `LibGit2Package` | `LibGit2Package/` | Swift Package wrapper |
| `LibGit2.swift` | `LibGit2Package/Sources/LibGit2/` | Swift API layer |
| `GitLFS.swift` | `LibGit2Package/Sources/LibGit2/` | Vanilla LFS batch + PUT/GET |
| `MTLSTransport.swift` | `LibGit2Package/Sources/LibGit2/` | Custom mTLS transport |

## Building libgit2

libgit2 is built as an XCFramework supporting:

- **ios-arm64**: Physical iOS devices
- **ios-arm64-simulator**: iOS Simulator on Apple Silicon

The framework is pre-built and included in the repository.

## Swift Wrapper

The Swift wrapper provides a type-safe API over libgit2's C interface:

```swift
// Repository operations
let repo = try Repository.open(at: path)
try repo.commit(message: "Add photo", author: signature)

// Index operations
try repo.add(path: "manifests/device/Original/photo.yaml")

// Remote operations
try repo.push(remote: "origin", branch: "main")
try repo.pullRebase(remote: "origin", branch: "main")
```

## Memory Management

libgit2 uses C-style memory management. The Swift wrapper handles:

- Automatic cleanup of libgit2 objects via `defer` blocks
- Proper error propagation from C error codes to Swift errors
- Safe conversion between C strings and Swift strings

### Example Pattern

```swift
func getHeadCommit() throws -> Commit {
    var oid = git_oid()
    let error = git_reference_name_to_id(&oid, repo, "HEAD")
    guard error == 0 else {
        throw GitError(code: error)
    }
    defer { git_object_free(commit) }
    
    var commit: OpaquePointer?
    git_commit_lookup(&commit, repo, &oid)
    return Commit(commit!)
}
```

## Custom mTLS Transport

For network operations requiring client certificate authentication, libgit2 uses a custom smart transport registered for the `mtls+https://` URL scheme.

See [Authentication](../gitdb/authentication.md) for details on the mTLS transport implementation.

## Supported Operations

| Operation | Method |
|-----------|--------|
| Open repository | `Repository.open(at:)` |
| Clone repository | `Repository.clone(from:to:)` |
| Stage files | `repo.add(path:)` |
| Commit changes | `repo.commit(message:author:)` |
| Push to remote | `repo.push(remote:branch:)` |
| Pull with rebase | `repo.pullRebase(remote:branch:)` |
| Read tree | `repo.tree(at:)` |
| Read blob | `repo.blob(at:)` |

## Advantages

- **Active maintenance**: Regular updates and security patches
- **Platform compatibility**: Works on iOS, macOS, Linux, Windows
- **Complete control**: Direct access to full libgit2 feature set
- **Future-proof**: Compatible with current and future Xcode versions

## Trade-offs

- **Wrapper maintenance**: Must maintain Swift wrapper layer
- **Verbose API**: C API is more verbose than Swift-native interfaces
- **Manual memory**: Need to manage memory through C interop
- **Abstraction effort**: Additional work for Swift-friendly interfaces
