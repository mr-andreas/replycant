# ADR-0007: Git LFS Test Infrastructure

## Status

Accepted

## Context

The application uses Git repositories with LFS for storing media files (as documented in ADR-0001, ADR-0002, and ADR-0004). Testing this functionality requires simulating both the Git repository structure and the LFS server without depending on external services or network connectivity.

We have two distinct testing scenarios:
1. **Unit tests** - Run in the same process as the test suite, with full access to test internals
2. **UI tests** - Run in a separate process from the app, requiring realistic end-to-end behavior

Options considered:
1. **Use a real external LFS server**: Requires network, external dependencies, and complicated setup
2. **Mock at the network layer**: Complex to intercept URLSession calls, especially in UI tests
3. **In-process mock servers**: Create lightweight HTTP servers that run within the test environment
4. **File system bypass**: Write binary data directly to disk (violates ADR-0002 architecture)

## Decision

We will implement **two separate mock LFS infrastructures** tailored to each testing context:

### For Unit Tests: MockLFSServer (Synchronous)

Located in `iosappTests/MockLFSServer.swift`, this provides:
- In-memory storage of binary data keyed by OID
- Synchronous helper methods (`uploadData()`, `downloadData()`)
- Batch API response simulation
- Request logging for test assertions
- No actual HTTP server - purely functional simulation

**Usage Pattern:**
```swift
let mockServer = MockLFSServer()
let imageData = Data(/* test image */)
let (oid, size) = mockServer.uploadData(imageData)
let retrieved = try mockServer.downloadData(oid: oid, size: size)
```

### For UI Tests: TestLFSServer (HTTP Server)

Located in `iosapp/TestLFSServer.swift`, this provides:
- Actual HTTP server on `localhost:9999` using Network framework
- Runs in the app process when `--uitesting` flag is present
- Implements Git LFS Batch API endpoints (`/lfs/objects/batch`)
- Serves binary downloads (`/lfs/objects/{oid}`)
- In-memory storage accessible via `TestLFSServer.shared.store()`

**Usage Pattern:**
```swift
// In app startup when --uitesting flag present
try TestLFSServer.shared.start()

// In test setup
TestLFSServer.shared.store(oid: sha256Hash, data: imageData)

// App makes real HTTP requests to http://localhost:9999/lfs
```

### Test Data Setup

The `TestSupport.swift` file orchestrates test environment setup:
1. Starts TestLFSServer on port 9999
2. Creates Git repository with proper structure
3. Generates real JPEG image data using UIKit
4. Stores image data in TestLFSServer
5. Commits LFS pointer files (not binary data) to Git
6. Sets UserDefaults to point to test LFS URL

This maintains the proper separation between Git (tracking pointers) and LFS (storing binaries) as defined in ADR-0002.

## Consequences

### Positive

- **Architectural fidelity**: UI tests exercise the real HTTP/LFS download path
- **No external dependencies**: Tests run offline without real LFS servers
- **Fast execution**: In-memory storage, no disk I/O for test data
- **Process isolation**: UI tests properly simulate production architecture
- **Debugging capability**: Request logs help diagnose test failures
- **Flexible test data**: Easy to create test images with specific characteristics

### Negative

- **Dual implementation burden**: Must maintain two separate mock servers
- **Port conflicts**: TestLFSServer requires port 9999 to be available
- **Limited HTTP implementation**: Simple server may not catch all edge cases
- **UIKit dependency in tests**: Test setup requires UIKit for image generation
- **Memory constraints**: All test data stored in memory (acceptable for small test suites)

### Implementation Notes

- MockLFSServer is stateless and can be instantiated per-test for isolation
- TestLFSServer is a singleton that persists for the app lifetime during UI tests
- Test data uses gradient-colored JPEGs with seed-based colors for visual distinction
- The `--uitesting` launch argument gates all test-specific code paths
- Port 9999 chosen as unlikely to conflict with typical development services
- Network framework (NWListener) provides lightweight HTTP without external dependencies

### Testing Guidelines

**For unit tests:**
- Use MockLFSServer for testing Git/LFS logic in isolation
- Create fresh instances per test for isolation
- Access request logs to verify correct LFS protocol usage

**For UI tests:**
- TestLFSServer starts automatically with `--uitesting` flag
- Store test data via `TestLFSServer.shared.store()` before tests run
- Test setup happens in `TestSupport.setupTestEnvironment()`
- Clean repository created fresh for each test run

### Migration Path

If the simple HTTP server proves insufficient:
1. Consider using a proper HTTP mocking framework (e.g., OHHTTPStubs)
2. Or implement a more complete HTTP/1.1 server
3. Current implementation handles batch API and binary downloads, which covers all current needs

## Related ADRs

- ADR-0001: Use libgit2 for Git operations
- ADR-0002: Manual Git LFS Implementation (defines pointer file format and HTTP protocol)
- ADR-0004: Original Media Storage Architecture (defines how originals are stored in LFS)
- ADR-0005: Thumbnail Storage Architecture (defines how thumbnails are stored in LFS)

