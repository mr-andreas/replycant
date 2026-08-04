# Replycant iOS

Replycant iOS is a native iOS application for managing and synchronizing your photo library with Git-backed storage.

## Overview

The app provides a seamless experience for viewing, organizing, and syncing photos across devices. All data is stored in a Git repository using GitDB, enabling version control, distributed synchronization, and secure multi-device access.

## Architecture

The iOS app is built with:

- **SwiftUI** - Modern declarative UI framework
- **libgit2** - Native Git operations via C library
- **Git LFS** - Efficient handling of large media files
- **mTLS** - Mutual TLS for secure device authentication
- **iOS Keychain** - Secure storage of cryptographic keys

## Key Features

### Photo Timeline
A sparse-loaded grid view sized by total timeline count, with on-demand page loading and thumbnail batch fetches.

### Offline-First Design
Full functionality without network access. Changes sync when connectivity is restored.

### Multi-Device Sync
Secure device linking via QR codes. Each device maintains its own namespace while sharing the same repository.

### Secure Authentication
ECDSA P-256 client certificates stored in the iOS Keychain (with optional Secure Enclave support).

## Core Components

| Component | Purpose |
|-----------|---------|
| `PhotoSyncManager` | Coordinates photo upload and sync operations |
| `GitRepository` | Swift wrapper around libgit2 for Git operations |
| `ClientIdentityManager` | Manages device identity and certificates |
| `GitDB` | Registration-driven SQLite manifest database, git sync engine, and generic query API |
| `TimelineManager` | Sparse timeline region loading and reactive mutation handling |
| `TimelineView` | Main photo grid UI |

## Documentation

- [libgit2 Integration](./libgit2-integration.md) - How Git operations are implemented
- [Git LFS](./git-lfs.md) - Manual LFS implementation for binary files
- [Thumbnails](./thumbnails.md) - Thumbnail generation and storage
- [GitDB Package](./gitdb-package.md) - Registration API, dynamic tables, sync, and query architecture
- [SQLite Manifest Cache](./sqlite-manifest-cache.md) - Database schema, pub-sub, and sparse timeline flow
- [Device Identity](./device-identity.md) - Immutable device identity design
- [Testing](./testing.md) - Mock LFS servers for unit and UI tests
