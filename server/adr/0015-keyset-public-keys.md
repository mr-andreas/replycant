# ADR-0015: Key sets for public keys

## Status

Accepted

## Context

Each key holder was two files, `pubkeys/<name>.pub` and
`pubkeys/<name>.age`. Recovery keys were the same pair with
`.recovery` in the file name. The only label was that file name, so
Settings could not show the name a person had given a device.

The files have to stay readable by gitd. gitd authorizes mTLS before
any device has unwrapped the KEK, and it never holds that key.

## Decision

One plaintext file per key holder, `pubkeys/<name>.yaml`, kind
`KeySet` (`gitdb.replycant.com/v1alpha1`).

- `metadata.name` equals the file name. `spec.type` is `device` or
  `recovery`. `spec.mtlsPublicKey` and `spec.agePublicKey` are the two
  public keys.
- `spec.displayName` is optional. It is AES-256-GCM under the KEK, and
  the additional data is `replycant-keyset-display-name-v1` followed
  by `metadata.name`. A server that copies the ciphertext onto another
  key set fails authentication. Readers that cannot open it show the
  slug.
- The file stays outside `manifests/`. That tree is fail-closed
  encrypted in the clients and in gitcrypt. A plaintext exception
  there would punch a hole in each of those checks.
- `gitdb/version` is 2. On boot, before it listens, gitd rewrites a
  version 1 library into key sets in one commit. The step copies keys
  unchanged and refuses to drop an unpaired or unreadable file.
  Clients built for version 1 refuse the result, so they have to be
  updated. A missing marker is an error, not a stand-in version.

## Consequences

### Positive

- A device and its age key cannot drift apart, and a recovery key is
  an explicit type rather than a filename suffix.
- Settings can show a real device name once a client that holds the
  KEK has written it. gitd's migration cannot, and does not pretend to.

### Negative

- Every current app has to be updated. An old app will not open a
  library after gitd has migrated it.
- While gitd is rewriting `main`, hsproxy still has the previous
  commit cached and authorizes nobody. The window ends when the
  migration commit lands.

## References

- [Encryption](../../docs/docs/gitdb/encryption.md)
- [Database format version](../../docs/docs/gitdb/database-version.md)
