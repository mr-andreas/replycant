# libgit2 Integration Guide

## ✅ Completed Integration

**libgit2 is now fully integrated and working!**

1. **Built libgit2 for iOS**
   - Created XCFramework at: `libgit2.xcframework`
   - Supports iOS device (arm64) and iOS Simulator (arm64)
   - Configured with HTTPS/TLS support via SecureTransport (Apple's native TLS)
   - No SSH support (network operations use mtls+https:// URLs with MTLSTransport)
   - Build script: `rebuild-with-tls.sh`

2. **Created Swift Package Wrapper**
   - Package location: `LibGit2Package/`
   - Exposes libgit2 C API to Swift via `Clibgit2` module
   - Includes Swift wrapper classes (`Git`, `Repository`)

3. **Integrated with Xcode**
   - Project: `iosapp.xcodeproj` (**use this!**)
   - Package is integrated and builds successfully
   - All system frameworks linked (Security, CoreFoundation, z, iconv)

## 🚀 Using the App

The app is ready to use! Just build and run:

```bash
open iosapp.xcodeproj
# Then: Product > Run (⌘R)
```

The app will display the libgit2 version on launch.

## 🔧 Using libgit2

### Basic Example (Already in ContentView.swift)

```swift
import LibGit2

// Initialize libgit2
try Git.initialize()

// Get version
let version = Git.version
print("libgit2 version: \\(version)")

// Open a repository
let repo = try Repository(path: "/path/to/repo")
print("Repository path: \\(repo.path ?? "")")
print("Is bare: \\(repo.isBare)")

// Create a new repository
let newRepo = try Repository.create(at: "/path/to/new/repo", bare: false)
```

### Available APIs

- `Git.initialize()` - Initialize libgit2
- `Git.shutdown()` - Shutdown libgit2  
- `Git.version` - Get libgit2 version string
- `Repository(path:)` - Open existing repository
- `Repository.create(at:bare:)` - Create new repository

The package exposes the full libgit2 C API via the `libgit2` module for advanced usage.

## 📁 Project Structure

```
iosapp/
├── libgit2.xcframework/          # Pre-built libgit2 for iOS
├── LibGit2Package/                # Swift package wrapper
│   ├── Package.swift
│   └── Sources/
│       ├── Clibgit2/             # C headers
│       └── LibGit2/              # Swift wrapper
└── iosapp.xcodeproj/             # Project (use this!)
```

For full libgit2 documentation, visit: https://libgit2.org/docs/

