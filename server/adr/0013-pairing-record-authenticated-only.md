# ADR-0013: Pairing Record Authenticated Only

## Status
Accepted. Supersedes the double seal and the manual-exposure delivery in
[ADR-0010](0010-headscale-tailnet-transport.md), and the CA-label check that
grew up beside the pairing record.

## Context
ADR-0011 left the pairing record holding two fields: the control-plane URL
and the deployment CA. Neither is a secret. The URL is a hostname derived
from the CA, and the device is about to pin that CA.

The record still carried three protections, each implemented in Go, Swift,
and TypeScript:

- an AEAD under the pairing secret, which is what stops a planted record
  from opening
- an inner age layer to the device key, which hid data that is not
  confidential
- a check that the CA hashes to the hostname's first label. Only gitd can
  write a record that opens, and gitd reads its own CA, so the check could
  not catch a record the AEAD had already authenticated

Manual exposure was the other half. gitd returned the sealed record from
`POST /pair` so an authorizing device could show a second QR, and compose
grew `REPLYCANT_HEADSCALE_URL` and `REPLYCANT_HSPROXY_BIND` for operators
who published headscale themselves. No client ever displayed or scanned
that second QR.

## Decision
The pairing record is one AES-GCM ciphertext under the wrap key derived
from the pairing secret. The slot stays associated data, so a valid record
cannot be moved to another slot. There is no age layer, no envelope, and
no CA-label check.

The discovery API is the only delivery path.

- `POST /pair` takes `pairing_secret` and answers `204` once the record is
  stored. The response body is empty.
- `--discovery-url` is required.
- `REPLYCANT_HEADSCALE_URL` and `REPLYCANT_HSPROXY_BIND` are removed.
  `hsproxy` binds to `127.0.0.1`. The tunnel hostname is always derived
  from the CA.

The device QR still carries `age_pubkey`. The authorizing device commits
it to `pubkeys/` so later epoch wraps include the new device.

## Consequences

### Positive
- One cryptographic construction, shared by the three clients, instead of
  two layers and a hostname check.
- One way for a pairing record to arrive.

### Negative
- A deployment cannot onboard a second device without the hosted discovery
  API, and cannot publish its control plane except through the hosted relay.
