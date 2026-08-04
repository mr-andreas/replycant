# ADR-0001: Use libgit2 for Git Operations

## Status

Accepted

## Context

The iOS application requires native Git repository handling capabilities. Two main options were evaluated:

1. **libgit2**: A portable, pure C implementation of the Git core methods provided as a linkable library. It is actively maintained and widely used across multiple platforms.

2. **Swiftgit2**: A Swift wrapper around libgit2 that provides a more Swift-friendly API. However, investigation revealed that this library is unmaintained and does not compile with recent Xcode versions.

## Decision

We will use libgit2 directly for handling Git repositories in the iOS application.

## Consequences

### Positive
- Active maintenance and community support
- Proven stability across platforms including iOS
- Complete control over the C API with the ability to create custom Swift wrappers
- Compatible with current and future Xcode versions
- Direct access to libgit2's full feature set

### Negative
- Requires building and maintaining our own Swift wrapper layer
- More verbose C API compared to Swift-native interfaces
- Need to manage memory manually through C interop
- Additional effort needed for Swift-friendly abstractions

### Implementation Notes
- Built libgit2 as an XCFramework for iOS (arm64) and iOS Simulator (arm64)
- Created LibGit2Package as a Swift Package wrapper around the XCFramework
- Implemented Swift wrapper layer in `LibGit2Package/Sources/LibGit2/LibGit2.swift`

