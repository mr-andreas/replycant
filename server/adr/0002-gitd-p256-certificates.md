# ADR 0002: gitd - Switch from Ed25519 to P-256 ECDSA Certificates

## Status

Accepted

## Context

ADR-0001 established mTLS authentication using Ed25519 keys. While Ed25519 provides excellent security and small key sizes, P-256 (secp256r1/prime256v1) ECDSA offers broader compatibility:

1. **Hardware Security Module (HSM) Support:** P-256 is widely supported by hardware security modules and secure enclaves (e.g., Apple Secure Enclave, Android Keystore), enabling key generation and signing in tamper-resistant hardware.
2. **Platform Compatibility:** P-256 is supported by all major TLS libraries and has broader tooling support than Ed25519 in some environments.
3. **Standard Compliance:** P-256 is approved by NIST and required by many compliance frameworks, making it suitable for enterprise deployments.
4. **SSH Compatibility:** OpenSSH supports P-256 keys (`ecdsa-sha2-nistp256`), maintaining the multi-purpose key capability from ADR-0001.

## Decision

We will replace Ed25519 with P-256 ECDSA for all certificate operations in gitd:

### Key Format Change

**Before (Ed25519):**
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host
```

**After (P-256):**
```
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY... user@host
```

### Certificate Generation Change

**Before:**
```bash
openssl genpkey -algorithm ED25519 -out client.key
```

**After:**
```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out client.key
```

### Authentication Flow

The authentication flow remains identical to ADR-0001:

1. Server requires TLS 1.3 with client certificate authentication
2. Client presents self-signed X.509 certificate containing P-256 public key
3. Server extracts P-256 public key from certificate (curve + X,Y coordinates)
4. Server loads authorized keys from `pubkeys/` on main branch (cached)
5. Server compares public key curve and coordinates for authentication
6. If authorized, request is proxied to git-http-backend via CGI

### Bootstrap Mode

Bootstrap mode behavior is unchanged from ADR-0001, except:
- Any valid **P-256** (instead of Ed25519) certificate is accepted for empty repositories

### Key Comparison

Ed25519 keys are 32-byte raw values that can be compared directly. P-256 keys require comparing:
- The elliptic curve (must be P-256)
- The X coordinate (32 bytes)
- The Y coordinate (32 bytes)

The Go `ecdsa.PublicKey.Equal()` method handles this comparison correctly.

## Consequences

### Positive

- **HSM Compatibility:** Keys can be generated and stored in hardware security modules
- **Broader Platform Support:** Works with more enterprise security infrastructure
- **Compliance Ready:** Meets NIST and government security requirements
- **Maintained SSH Compatibility:** Same key can still be used for SSH authentication
- **No Architectural Changes:** Only the cryptographic primitive changes; all flows remain identical

### Negative

- **Larger Keys:** P-256 keys are larger than Ed25519 (65 bytes vs 32 bytes for public key)
- **Slower Operations:** ECDSA signing/verification is slower than Ed25519, though negligible for authentication use case
- **Existing Keys Incompatible:** Users must regenerate keys and certificates
- **Migration Required:** Existing deployments need key rotation

### Migration Path

1. Generate new P-256 keys for all users
2. Update `pubkeys/` directory with new public keys
3. Update server and CA certificates if applicable
4. Regenerate client certificates
5. Update git configuration with new credentials

## Supersedes

This ADR supersedes [ADR-0001](0001-gitd-mtls-authentication.md). All decisions from ADR-0001 remain in effect except for the change from Ed25519 to P-256 ECDSA.



