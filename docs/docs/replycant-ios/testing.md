# Testing

The iOS app includes specialized test infrastructure for Git LFS operations. Two separate mock LFS servers are used for different testing contexts.

## Testing Contexts

| Context | Challenge |
|---------|-----------|
| Unit tests | Run in same process, need fast synchronous access |
| UI tests | Run in separate process, need realistic HTTP behavior |

## MockLFSServer (Unit Tests)

Located in `iosappTests/MockLFSServer.swift`, this provides in-memory LFS simulation for unit tests.

### Features

- In-memory storage keyed by OID
- Synchronous helper methods
- Batch API response simulation
- Request logging for assertions
- No actual HTTP server

### Usage

```swift
let mockServer = MockLFSServer()

// Upload test data
let imageData = Data(/* test image */)
let (oid, size) = mockServer.uploadData(imageData)

// Download and verify
let retrieved = try mockServer.downloadData(oid: oid, size: size)
XCTAssertEqual(imageData, retrieved)

// Check request logs
XCTAssertEqual(mockServer.uploadRequests.count, 1)
```

### Benefits

- **Fast execution**: No network overhead
- **Isolated tests**: Fresh instance per test
- **Assertions**: Verify correct LFS protocol usage

## TestLFSServer (UI Tests)

Located in `iosapp/TestLFSServer.swift`, this provides a real HTTP server for UI tests.

### Features

- HTTP server on `localhost:9999`
- Uses iOS Network framework (`NWListener`)
- Implements Git LFS Batch API (`/lfs/objects/batch`)
- Serves binary downloads (`/lfs/objects/{oid}`)
- In-memory storage via `TestLFSServer.shared`

### Architecture

```
UI Test Process                    App Process
      │                                 │
      │                    ┌────────────┴────────────┐
      │                    │     TestLFSServer       │
      │                    │    localhost:9999       │
      │                    └────────────┬────────────┘
      │                                 │
      └─────── Test Setup ──────────────┘
```

### Activation

The server starts when the app launches with `--uitesting` flag:

```swift
// In app startup
if ProcessInfo.processInfo.arguments.contains("--uitesting") {
    try TestLFSServer.shared.start()
}
```

### Test Data Setup

```swift
// Store test data before tests run
TestLFSServer.shared.store(oid: sha256Hash, data: imageData)

// App makes real HTTP requests to http://localhost:9999/lfs
```

## Test Environment Setup

`TestSupport.swift` orchestrates the complete test environment:

1. Start TestLFSServer on port 9999
2. Create Git repository with proper structure
3. Generate real JPEG image data using UIKit
4. Store image data in TestLFSServer
5. Commit LFS pointer files (not binaries) to Git
6. Configure UserDefaults to point to test LFS URL

This maintains proper separation between Git (tracking pointers) and LFS (storing binaries).

## Test Data Generation

Test images use gradient-colored JPEGs with seed-based colors:

```swift
func createTestImage(seed: Int) -> Data {
    let color = UIColor(hue: CGFloat(seed % 360) / 360.0, 
                        saturation: 0.8, 
                        brightness: 0.9, 
                        alpha: 1.0)
    // Generate gradient JPEG...
}
```

This provides visually distinct images for debugging.

## Guidelines

### For Unit Tests

- Use `MockLFSServer` for Git/LFS logic testing
- Create fresh instances per test for isolation
- Access request logs to verify protocol usage
- No network dependencies

### For UI Tests

- TestLFSServer starts automatically with `--uitesting`
- Store test data via `TestLFSServer.shared.store()`
- Test setup happens in `TestSupport.setupTestEnvironment()`
- Clean repository created fresh for each test run

## Implementation Notes

| Detail | Value |
|--------|-------|
| Port | 9999 (unlikely to conflict with dev services) |
| Framework | Network framework (`NWListener`) |
| Storage | In-memory only |
| Activation | `--uitesting` launch argument |

## Trade-offs

| Advantage | Trade-off |
|-----------|-----------|
| Architectural fidelity | Dual implementation burden |
| No external dependencies | Port 9999 must be available |
| Fast execution | Limited HTTP edge case coverage |
| Process isolation | UIKit dependency for image generation |

## Future Improvements

If the simple HTTP server proves insufficient:

1. Consider OHHTTPStubs or similar mocking framework
2. Implement more complete HTTP/1.1 server
3. Current implementation covers batch API and binary downloads

## Related Files

| File | Purpose |
|------|---------|
| `iosappTests/MockLFSServer.swift` | Unit test LFS mock |
| `iosapp/TestLFSServer.swift` | UI test HTTP server |
| `iosapp/TestSupport.swift` | Test environment setup |
| `iosappTests/TestHelpers.swift` | Common test utilities |
| `iosappTests/TestFixtures.swift` | Test data generation |
