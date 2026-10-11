# ADR-0012: Refused Key Requests Answer 403

## Status
Accepted. Refines
[ADR-0011](0011-headscale-state-derived-from-git.md) on what an unknown
certificate hears when it asks for a pre-auth key.

## Context
ADR-0011 has `hsproxy` close any unauthorized session without a reply, so a
probe learns nothing about what is behind the tunnel. That is right for
control traffic: the session is a long-lived byte stream, and there is no
status code a client could read.

A key request is different. The iOS client treats `403` on
`POST /replycant/preauthkey` as "this certificate is not in `pubkeys/`" and
shows the recovery-key-rejected screen. A connection that closes after the
TLS handshake looks the same as a network fault, so a deleted recovery key
was reported as a generic error. The device has already presented a
certificate and finished the handshake, so answering `403` on this one path
does not tell a probe anything the handshake did not.

## Decision
After the handshake, `hsproxy` peeks the request line for every certificate,
including ones that are not in `pubkeys/`.

- A key request from an unknown certificate is answered `403`. No key is
  minted and headscale is not dialed. Sessions admitted under the
  empty-repository bootstrap exemption keep the same `403`.
- Every other request from an unknown certificate is still closed with no
  reply, and headscale is not dialed.

## Consequences

### Positive
- A revoked device can tell "this key was removed" from "the network failed".

### Negative
- A probe that already completed a handshake can confirm the key path
  exists. It learns nothing about headscale, and it cannot obtain a key.
