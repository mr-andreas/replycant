# Device Identity

Each device has an immutable cryptographic identity that persists for the lifetime of the app installation. This identity is used for mTLS authentication with the Git server.

## Core Principle

**Device identity is immutable once generated.** The key pair cannot be regenerated or deleted through normal app operations. This ensures reliable authentication and prevents accidental data loss.

## Why Immutable Identity

Allowing identity regeneration caused critical problems:

| Problem | Consequence |
|---------|-------------|
| Authentication failure | New key doesn't match public key in repository |
| Data loss | Can't access encrypted data after key change |
| Linking failures | Key changes during multi-device linking flow |
| Unpredictable behavior | Multiple code paths could trigger regeneration |

## Identity Lifecycle

### Generation

Identity is generated exactly once, during first launch:

**Bootstrap Flow** (new repository):
1. User scans server config QR
2. Identity generated
3. Public key committed and pushed

**Connect Flow** (joining existing repository):
1. User chooses to link to existing device
2. Identity generated
3. Public key displayed as QR for other device to scan

### Persistence

After generation, the identity persists indefinitely:

- Private key stored in iOS Keychain
- Survives app updates
- Survives device reboots
- Only cleared by app uninstall

## Implementation

### Key Function

```swift
// Idempotent: generates only if no identity exists
func generateIdentityIfNeeded() throws {
    guard !hasExistingIdentity() else { return }
    try generateNewIdentity()
}
```

### Removed Functions

The `deleteIdentity()` function was completely removed to enforce immutability at the code level.

### Call Sites

Both onboarding flows use the idempotent function:

- `OnboardingView.performBootstrapSetup()`
- `OnboardingView.startConnectToExisting()`

## Security Properties

| Property | Implementation |
|----------|---------------|
| Key type | ECDSA P-256 |
| Storage | iOS Keychain |
| Hardware backing | Secure Enclave (optional) |
| Deletion | App uninstall only |
| Regeneration | Not possible |

## Recovery Scenarios

### Lost Keychain Data

If Keychain data is lost (rare but possible with iOS backup/restore issues):

1. Device permanently loses access
2. Must remove old public key from repository (from another device)
3. Uninstall and reinstall app
4. Go through device linking flow again

### Compromised Key

If a private key is compromised:

1. Uninstall the app (clears Keychain)
2. Remove the old public key from `pubkeys/` directory
3. Reinstall the app
4. Re-link the device

There is no built-in key rotation mechanism by design.

### Orphaned Device

If a device can't authenticate (401 error) due to key mismatch:

1. Check if device can authenticate with server
2. If authentication fails, device is "orphaned"
3. User must manually remove old public key (from another device)
4. Uninstall/reinstall to clear Keychain
5. Complete device linking flow again

## Design Rationale

### Why No Key Rotation

Key rotation adds complexity and still has failure windows:

- Window between key generation and successful push
- Doesn't solve multi-device linking problems
- Recovery still requires manual intervention

### Why No Reset Feature

The `deleteIdentity()` function was removed entirely because:

- App uninstall is the only safe reset mechanism
- Users understand uninstall is destructive
- Prevents accidental identity deletion
- Simplifies code and reduces error cases

## Testing Considerations

During development, testing different onboarding flows requires:

1. Uninstall the app to clear Keychain
2. Reinstall fresh
3. The identity persists across app launches otherwise

## Related Documentation

- [Authentication](../gitdb/authentication.md) - mTLS protocol details
- [libgit2 Integration](./libgit2-integration.md) - How identity is used for Git operations
