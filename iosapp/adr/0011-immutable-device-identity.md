# ADR-0011: Immutable Device Identity

## Status

Accepted

## Context

Each device generates an ECDSA P-256 key pair for mTLS authentication with the git server. The private key is stored in the iOS Keychain (or Secure Enclave when available) and the corresponding public key is committed to the `pubkeys/` directory in the repository.

During initial implementation, the `generateIdentity()` function would delete any existing identity and create a new one. This created several critical problems:

1. **Authentication Failure**: If a device regenerated its key after the public key was already pushed to the repository, the private key would no longer match the public key on the server, causing permanent 401 authentication failures.

2. **Data Loss**: Once a device's public key is added to the repository and the device syncs encrypted data, regenerating the key means the device can no longer authenticate to access that data. This results in permanent data loss.

3. **Multi-Device Linking Failures**: During the device linking flow, if Device B regenerated its key between showing the QR code and cloning the repository, the key used for authentication wouldn't match the one Device A pushed to the server.

4. **Unpredictable Behavior**: Multiple code paths could trigger key regeneration (bootstrap setup, connect-to-existing flow, error recovery), making it difficult to reason about when a device would lose access to its data.

## Decision

**Device identity is now immutable for the lifetime of the app installation.**

### Implementation Changes

1. **Renamed Function**: `generateIdentity()` → `generateIdentityIfNeeded()`
   - The new function is idempotent
   - If an identity exists, it does nothing
   - If no identity exists, it generates one (first-time setup only)

2. **Removed Deletion Function**: `deleteIdentity()` has been completely removed
   - No code path can delete the identity once generated
   - Enforces immutability at the code level
   - Identity can only be cleared by uninstalling the app (iOS clears Keychain automatically)

3. **Updated All Call Sites**:
   - `OnboardingView.performBootstrapSetup()`: Uses `generateIdentityIfNeeded()`
   - `OnboardingView.startConnectToExisting()`: Uses `generateIdentityIfNeeded()`
   - Both flows now safely reuse existing identity if present

### Key Generation Timing

A device identity is generated exactly once, during one of these scenarios:

1. **First Launch - Bootstrap Flow**: User scans server config QR → identity generated → public key committed and pushed
2. **First Launch - Connect to Existing Flow**: User chooses to link to existing device → identity generated → public key shown as QR for other device to scan

After generation, the identity persists in the Keychain indefinitely.

## Consequences

### Positive

1. **Data Safety**: Devices can never accidentally lose access to their data by regenerating keys
2. **Reliable Authentication**: The private key always matches the public key in the repository
3. **Predictable Behavior**: Identity generation happens exactly once, making the system easier to reason about
4. **Multi-Device Linking Works**: Device B's key remains consistent throughout the linking flow

### Negative

1. **No Key Rotation**: If a private key is compromised, there's no built-in mechanism to rotate it. The user would need to:
   - Uninstall the app (clearing Keychain)
   - Remove the old public key from `pubkeys/` directory
   - Reinstall and re-link the device
   
2. **Lost Key = Lost Access**: If the Keychain data is lost (rare but possible with iOS backup/restore issues), the device permanently loses access. Recovery requires:
   - Removing the device's public key from the repository
   - Treating it as a new device and going through the linking flow again

3. **Testing Complexity**: During development, testing different onboarding flows requires app uninstall/reinstall to clear the Keychain, as the identity persists across app launches.

## Alternatives Considered

### 1. Key Rotation with Repository Update

Allow key regeneration but automatically update the repository:
- Generate new key pair
- Replace old public key in `pubkeys/` directory
- Commit and push the change

**Rejected because**: This adds significant complexity and still has a window where authentication fails (between key generation and successful push). It also doesn't solve the multi-device linking problem.

### 2. Separate Keys for Different Purposes

Use different keys for different operations (authentication, encryption, signing).

**Rejected because**: The current architecture uses a single key for mTLS authentication, which is sufficient. Adding multiple keys increases complexity without clear benefit.

### 3. Server-Side Key Management

Store private keys on the server with device authentication via password/biometrics.

**Rejected because**: This defeats the purpose of client-side key management and introduces a single point of failure. The current architecture keeps private keys on-device for better security.

## Migration Path

For existing installations that may have regenerated keys:

1. Check if the device can authenticate with the server
2. If authentication fails (401), the device is "orphaned"
3. User must manually remove the old public key from another device
4. Uninstall/reinstall the app to clear Keychain
5. Go through device linking flow again

Note: No "Reset Device Identity" feature exists because the `deleteIdentity()` function was removed entirely. Device reset can only happen via app uninstall, which is the safest approach as it ensures users understand they're performing a destructive action.

## References

- ADR-0009: ECDSA P-256 Client Certificates for mTLS
- ADR-0010: libgit2 Custom mTLS Transport
- `ClientIdentityManager.swift`: Implementation of identity management
