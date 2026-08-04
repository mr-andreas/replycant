# ADR-0010: libgit2 Custom mTLS Transport

## Status

Accepted (supersedes ADR-0008)

## Context

ADR-0008 established that Git network operations (push/pull) would be performed using URLSession with a custom implementation of the Git Smart HTTP protocol (`GitHTTPClient`), while libgit2 handled local Git operations only.

This approach had significant drawbacks:

1. **Protocol complexity**: Manually implementing Git Smart HTTP protocol requires handling pack negotiation, packfile generation, and report-status parsing correctly
2. **Packfile issues**: The custom packfile generation did not include all necessary objects for non-fast-forward pushes, causing "missing necessary objects" errors on the server
3. **Maintenance burden**: Two separate systems for Git operations (URLSession for network, libgit2 for local) with complex handoffs between them
4. **Error handling gaps**: Server-side rejections could be misinterpreted as successes due to incomplete report-status parsing

libgit2 already implements the full Git protocol correctly, including proper pack negotiation and error handling. The only gap was mTLS client certificate authentication.

## Decision

We will use libgit2 for all Git operations (local and network) by registering a **custom smart transport** for a new URL scheme (`mtls+https://`). This transport uses URLSession internally for mTLS authentication while letting libgit2 handle the Git protocol.

### Architecture

```
App → Remote URL (mtls+https://...) → libgit2 smart transport
    → Custom subtransport → URLSession (mTLS + pinned CA) → gitd server
```

### Key Points

1. **New URL scheme**: Register `mtls+https://` via `git_transport_register` so libgit2 routes these URLs through our custom transport
2. **Custom `git_smart_subtransport`**: Implements the HTTP layer for Git Smart HTTP protocol, delegating TLS/mTLS to URLSession
3. **libgit2 handles Git protocol**: Pack negotiation, packfile creation, ref updates, and report-status parsing are all handled by libgit2
4. **ECDSA P-256 client certificates**: As established in ADR-0009, we use P-256 keys stored as `SecIdentity` in the iOS Keychain
5. **Pinned CA validation**: Server certificate is validated against the pinned CA from `ServerConfigurationManager`

### Implementation Components

- **MTLSTransport**: C shim + Swift wrapper that registers the custom transport and implements `git_smart_subtransport`
- **Repository.push/pullRebase**: Existing libgit2-backed methods now work end-to-end
- **Remote URLs**: Stored as `mtls+https://server.local:8443/` instead of `https://...`

### Removed Components

- **GitHTTPClient**: Deleted entirely; no longer needed
- **Custom packfile generation**: libgit2 handles pack creation internally
- **Report-status parsing**: libgit2 handles error propagation from receive-pack

## Consequences

### Positive

- **Correct Git protocol implementation**: libgit2's battle-tested implementation handles all edge cases
- **Simpler architecture**: Single system for all Git operations
- **No libgit2 patches required**: Custom transport uses stable public APIs, making libgit2 upgrades straightforward
- **Better error handling**: libgit2 properly parses report-status and propagates errors
- **Reduced code**: Removing GitHTTPClient eliminates ~600 lines of custom protocol code

### Negative

- **Custom transport code**: Still need to maintain the subtransport implementation (~300 lines)
- **URL scheme change**: Existing repositories need remote URL migration from `https://` to `mtls+https://`
- **Debugging complexity**: Issues span Swift transport code and libgit2 internals

### Migration

Existing repositories will have their remote URLs updated from `https://...` to `mtls+https://...` automatically when the transport is initialized.

