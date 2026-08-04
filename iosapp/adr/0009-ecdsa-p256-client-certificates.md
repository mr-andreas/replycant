# ADR-0009: ECDSA P-256 Client Certificates for mTLS

## Status

Accepted (supersedes ADR-0008 for key type only)

## Context

ADR-0008 specified Ed25519 client certificates for mTLS authentication. However, during implementation, we discovered that iOS's Security framework does not support Ed25519 keys for `SecIdentity` creation, which is required for URLSession client certificate authentication.

When the server requests a client certificate, URLSession's delegate receives an `NSURLAuthenticationMethodClientCertificate` challenge. The delegate must respond with a `URLCredential` initialized from a `SecIdentity`. However:

1. `SecIdentity` requires a `SecKey` private key linked to a `SecCertificate` in the Keychain
2. `SecKeyCreateWithData` only supports RSA and ECDSA (P-256, P-384, P-521) key types
3. Ed25519 keys from CryptoKit cannot be converted to `SecKey` objects
4. Without a valid `SecIdentity`, URLSession falls back to "default handling" which sends no certificate, causing the server to reject the connection with "certificate required"

## Decision

We switch from Ed25519 to ECDSA P-256 (secp256r1/prime256v1) for client certificates. This provides:

1. **Native iOS SecIdentity support**: P-256 keys created with `SecKeyCreateRandomKey` can be stored directly in the Keychain
2. **Automatic key-certificate linking**: iOS automatically links certificates to their private keys, creating a `SecIdentity`
3. **Secure Enclave support**: P-256 keys can optionally be generated in the Secure Enclave for hardware-backed security
4. **Standard URLSession integration**: The `SecIdentity` works directly with `URLCredential` for mTLS

### Implementation Changes

- **ClientIdentityManager**: Generates P-256 keys using `SecKeyCreateRandomKey` with `kSecAttrKeyTypeECSECPrimeRandom`
- **Certificate format**: Uses ecdsa-with-SHA256 (OID 1.2.840.10045.4.3.2) instead of Ed25519
- **SSH public key format**: Changed from `ssh-ed25519` to `ecdsa-sha2-nistp256` for pubkeys/ directory
- **GitHTTPClient**: Loads `SecIdentity` directly and provides it to URLSession via `URLCredential`

## Consequences

### Positive

- mTLS authentication works correctly with URLSession
- Native iOS security integration via Keychain and optionally Secure Enclave
- Industry-standard algorithm with wide server support
- Simpler implementation without needing custom TLS handling

### Negative

- Requires server to support ECDSA P-256 client certificates (in addition to or instead of Ed25519)
- P-256 keys are 32 bytes larger than Ed25519 keys (64 bytes vs 32 bytes for public key)
- Slightly slower signature operations compared to Ed25519

### Server Requirements

The gitd server must be updated to accept ECDSA P-256 client certificates. The public key format in `pubkeys/` changes from:

```
ssh-ed25519 AAAA...
```

to:

```
ecdsa-sha2-nistp256 AAAA...
```

