# ADR-0008: mTLS Git Authentication with Ed25519 Client Certificates

## Status

Superseded by ADR-0010

## Context

The iOS application needs secure authentication for Git server communication. The server (`gitd`) uses mTLS with Ed25519 client certificates for authentication. Public keys are stored in the repository itself at `pubkeys/`, making access control self-contained and auditable through Git history.

Two approaches for implementing Git network operations were considered:

1. **libgit2 with custom transport**: Configure libgit2 to use client certificates for HTTPS. However, libgit2's iOS build doesn't have straightforward support for Ed25519 client certificates in TLS.

2. **URLSession with Git Smart HTTP protocol**: Use iOS's native URLSession with SecIdentity for mTLS, implementing the Git Smart HTTP protocol directly. This provides native iOS security features and Keychain integration.

## Decision

We will use URLSession for all Git network operations (push/pull) with mTLS authentication, while continuing to use libgit2 for local Git operations (commits, index management, tree manipulation).

### Key Generation and Storage

- Generate Ed25519 key pairs using CryptoKit (`Curve25519.Signing.PrivateKey`)
- Create self-signed X.509 certificates using DER encoding
- Store the private key and certificate as SecIdentity in the iOS Keychain
- Extract SSH-format public keys for committing to `pubkeys/` directory

### Server Configuration

- Obtain server URL and CA certificate by scanning a QR code
- Store configuration securely for subsequent app launches
- Pin the server's CA certificate for TLS validation

## Consequences

### Positive

- Native iOS security integration via Keychain
- Full control over TLS configuration and certificate pinning
- Compatible with the gitd server's Ed25519 mTLS authentication
- Auditable key management through Git history
- Bootstrap mode support for initializing empty repositories

### Negative

- Requires implementing Git Smart HTTP protocol
- Manual ASN.1/DER encoding needed for Ed25519 certificate creation
- Two systems for Git operations (URLSession for network, libgit2 for local)
- More code to maintain compared to a single unified approach

### Implementation Notes

- `ClientIdentityManager`: Handles Ed25519 key generation, X.509 certificate creation, and Keychain storage
- `GitHTTPClient`: Implements Git Smart HTTP protocol over URLSession with mTLS
- `ServerConfigurationManager`: Stores server URL and CA certificate
- `QRCodeScannerView`: Scans QR codes containing `{"ca": "...", "url": "..."}` JSON

