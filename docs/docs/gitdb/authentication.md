# Authentication

GitDB uses mutual TLS (mTLS) with ECDSA P-256 client certificates for secure authentication between devices and the Git server. Public keys are stored in the repository itself, making access control auditable through Git history.

## Overview

Authentication is based on client certificates:

1. Each device generates an ECDSA P-256 key pair
2. The public key is committed to the repository's `pubkeys/` directory
3. The private key is stored securely on the device
4. All Git and LFS operations use mTLS with the client certificate

## Why ECDSA P-256

ECDSA P-256 (secp256r1) was chosen over Ed25519 because:

- iOS's Security framework requires `SecIdentity` for client certificate authentication
- `SecIdentity` only supports RSA and ECDSA key types
- Ed25519 keys from CryptoKit cannot be converted to `SecKey` objects
- P-256 keys can optionally use the Secure Enclave for hardware-backed security

## Public Key Storage

Public keys are stored in the repository for auditable access control:

```
pubkeys/{device-identifier}.pub
```

### Format

Keys use SSH public key format for compatibility:

```
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABB...
```

### Access Control Flow

1. Device generates key pair during first launch
2. Public key is committed and pushed to the repository
3. Server validates client certificate against known public keys
4. Server rejects connections from unknown certificates

## mTLS Transport

Git operations use a custom URL scheme (`mtls+https://`) that routes through a custom libgit2 transport with mTLS support.

### Architecture

```
App → Remote URL (mtls+https://...) 
    → libgit2 smart transport 
    → Custom subtransport 
    → URLSession (mTLS + pinned CA) 
    → Git server
```

### Key Components

| Component | Responsibility |
|-----------|---------------|
| `mtls+https://` scheme | Signals libgit2 to use custom transport |
| Custom subtransport | Handles HTTP layer with mTLS |
| URLSession | Provides TLS with client certificate |
| Pinned CA | Validates server certificate |

### Benefits

Using libgit2's smart transport with a custom subtransport provides:

- **Correct Git protocol**: libgit2's battle-tested implementation handles all edge cases
- **Simpler architecture**: Single system for all Git operations
- **Better error handling**: Proper propagation of server errors
- **No patches required**: Uses stable public APIs

## Server Configuration

Devices obtain server configuration by scanning a QR code containing:

```json
{
  "url": "mtls+https://server.example.com:8443/",
  "ca": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
}
```

The CA certificate is used to validate the server's identity (certificate
pinning). Clients derive the authenticated LFS endpoint from `url` as
`{origin(url)}/lfs`.

For webapp onboarding, server configuration is discovered programmatically from the CA server `/config.json` endpoint instead of scanning server-config QR data. Webapp linking QR payloads include `ca_hash` (SHA256 of CA DER bytes), which lets iOS verify the webapp connected to the same trusted CA before committing the new public key.

## Certificate Format

Client certificates are self-signed X.509 certificates:

- **Key Type**: ECDSA with P-256 curve
- **Signature Algorithm**: ecdsa-with-SHA256 (OID 1.2.840.10045.4.3.2)
- **Storage**: iOS Keychain as `SecIdentity`

## Security Properties

| Property | Implementation |
|----------|---------------|
| Client Authentication | ECDSA P-256 client certificate |
| Server Validation | Pinned CA certificate |
| Key Storage | iOS Keychain (optionally Secure Enclave) |
| Access Control | Public keys in Git repository |
| Audit Trail | Git history of pubkeys/ directory |

## Bootstrap Flow

### New Repository (First Device)

1. Scan server config QR code
2. Generate ECDSA P-256 key pair
3. Server accepts any certificate in bootstrap mode
4. Commit public key to `pubkeys/` directory
5. Push to establish access control

### Joining Existing Repository

1. Existing device displays new device's public key as QR
2. Existing device commits new public key to repository
3. New device can now authenticate with its certificate
