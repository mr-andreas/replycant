# ADR-0039: Encryption spaces

## Status

Proposed. Builds on
[ADR-0038](0038-keyset-and-exact-database-version.md) and server
[ADR-0015](../../server/adr/0015-keyset-public-keys.md).

## Context

Every manifest and binary lives in a device space,
`manifests/{space}/...` and `binary/{space}/...`, and every object is
encrypted with one library-wide KEK. A client can only read everything
or nothing.

Some clients should see only part of the library. An upload app should
add media without being able to read the rest. gitd should be able to
keep server information that every device can read, while gitd never
holds the library KEK.

The space name is also stored inside each encrypted manifest as
`metadata.deviceSpace`. gitd cannot rewrite that field, because it does
not hold the KEK.

## Decision

1. **Layout.** Each space is one folder, `encryptionspaces/{space}/`,
   with `manifests/` and `binary/` under it. The path is the only source
   of a file's space. New manifests do not write `metadata.deviceSpace`,
   and readers ignore it.
2. **Key set per space.** A space that contains
   `encryption/current` and `encryption/epochs/N.age` has its own key
   set. Any other space uses the global key set in `encryption/`. KEKs
   are looked up by key set root and epoch. Envelope formats and AAD do
   not change.
3. **No fallback.** An object in a space is decrypted only with a KEK
   from that space's key set. A client never falls back to the global
   KEK, never uses another space's KEK, and never tries several KEKs in
   turn. Otherwise a holder of any KEK could plant objects in a space it
   cannot read.
4. **Scoped key holders.** A `KeySet` with `spec.type: scoped` lists
   `spec.encryptionSpaces`. Global epochs are wrapped for `device` and
   `recovery` key sets. A space's own epochs are wrapped for those plus
   every `scoped` key set that lists the space. A scoped key set has no
   `displayName`, because that field is sealed with the global KEK.
5. **Fail closed.** Each client pins, per space, whether the space uses
   the global key set or its own. It refuses a change on a space it has
   already seen, and trusts a new space on first use. It treats any of
   these as an integrity violation:
   - an object that does not open with its space's key set
   - a missing epoch
   - a plaintext object
   - a mode change
   - a space key set that a `device` or `recovery` key cannot unwrap

   On a violation it stops syncing, writes nothing, and shows a
   persistent error. Command-line tools exit with an error.
6. **Migration.** `gitdb/version` becomes 3. gitd's boot-migration
   runner gains a step from 2 to 3. It moves `manifests/{space}/...` and
   `binary/{space}/...` under `encryptionspaces/{space}/`, with
   unchanged contents. Every migrated space uses the global key set.
7. **Creating a space.** Any client with Git access can create a space
   by writing its first epoch, wrapped for every `device` and
   `recovery` key set and for itself. It does not need any existing
   KEK.

## Consequences

### Positive

- A client can be given access to one space without access to the
  rest of the library.
- gitd can later create its own space for server information without
  holding the library KEK. It would wrap that space's key set for every
  existing device and recovery key.
- The migration needs no keys and leaves every encrypted object and LFS
  object untouched.

### Negative

- Device link, recovery, and revocation have to re-wrap or rotate every
  space with its own key set, not just the global one.
- Epoch files and key sets are still unauthenticated plaintext. Any Git
  writer can add a forged epoch to a key set, and scoped clients widen
  who can write. Required signed commits, verified per space, are left
  to a later decision.
- A new space is trusted on first use, and so is every space on a
  freshly installed client.
- The migration runner holds every plaintext blob of `main` in memory,
  and this step touches every manifest and pointer.

## References

- ADR-0028: GitDB database format version
- ADR-0038: Key sets and an exact database version
- [Encryption](../../docs/docs/gitdb/encryption.md)
- [Database format version](../../docs/docs/gitdb/database-version.md)
