# GitDB

GitDB is a YAML-based database stored in Git that provides version-controlled data management for the Replycant ecosystem.

## Overview

GitDB uses Git as the underlying storage and version control system, with all data stored as Kubernetes-style YAML manifests. This approach provides complete version history, distributed synchronization, and human-readable data formats.

## Core Concepts

### Manifest-Based Storage

All data in GitDB is stored as YAML manifest files following a Kubernetes-style structure:

```yaml
apiVersion: [api-version-identifier]
kind: [resource-type]
metadata:
  name: [object-name]
spec:
  # Resource-specific fields
status:
  # Operational state (optional)
```

### Encryption Spaces

Every object in GitDB belongs to an encryption space, stored under `encryptionspaces/{space}/`. Each device writes into its own space, which prevents naming conflicts when multiple devices sync to the same repository. A space can also have its own encryption keys, so a client can be limited to just that space. See [Encryption spaces](./encryption.md#encryption-spaces).

### Git LFS Integration

Large binary files (photos, videos) are stored using Git Large File Storage (LFS). The Git repository contains small pointer files while the actual binary data is stored on the LFS server.

## Documentation

- [Key Features](./key-features.md) - What GitDB helps Replycant achieve
- [Manifests](./manifests.md) - Manifest structure, storage paths, and naming conventions
- [Media Storage](./media-storage.md) - How original media files are stored
- [Schema Validation](./schema-validation.md) - JSON Schema for manifest validation
- [Authentication](./authentication.md) - mTLS authentication protocol
- [Server Architecture](./server-architecture.md) - gitd server internals and CA distribution
- [LFS Push Validation](./lfs-push-validation.md) - Pre-receive enforcement for missing LFS objects
- [Database Format Version](./database-version.md) - Repo-level layout marker that clients pin and refuse to mismatch
