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
   `encryption/current`, `encryption/epochs/N.age`, and
   `encryption/recipients.yaml` has its own key set. Any other space
   uses the global key set in `encryption/`, which also gains a
   `recipients.yaml`. KEKs are looked up by key set root and epoch.
   Envelope formats and AAD do not change.
3. **No fallback.** An object in a space is decrypted only with a KEK
   from that space's key set. A client never falls back to the global
   KEK, never uses another space's KEK, and never tries several KEKs in
   turn. Otherwise a holder of any KEK could plant objects in a space it
   cannot read.
4. **Recipient lists, not key types.** Each key set's `recipients.yaml`
   names its members by KeySet name. The global list has only
   `members`. A space's list also has a policy: `library` means every
   global member plus its own `members`, and `explicit` means only its
   own `members`. A key holder maps to any number of spaces through the
   lists that name it. `spec.type` (`device`, `recovery`, `app`) is
   descriptive only. It chooses the Settings section and has no
   technical effect. A key holder that is not a global member has no
   `displayName`, because that field is sealed with the global KEK.
5. **Fail closed.** A client opens only the key sets whose resolved
   recipients include its own KeySet. Each client pins, per space,
   whether the space uses the global key set or its own. It refuses a
   change on a space it has already seen, and trusts a new space on
   first use. In a key set it is a recipient of, it treats any of these
   as an integrity violation:
   - an object that does not open with its space's key set
   - a missing epoch
   - a plaintext object
   - a mode change
   - an epoch it cannot unwrap although it is listed
   - a missing or invalid `recipients.yaml`

   On a violation it stops syncing, writes nothing, and shows a
   persistent error. Command-line tools exit with an error.
6. **Migration.** `gitdb/version` becomes 3. gitd's boot-migration
   runner gains a step from 2 to 3. It moves `manifests/{space}/...` and
   `binary/{space}/...` under `encryptionspaces/{space}/`, with
   unchanged contents. Every migrated space uses the global key set.
   It writes `encryption/recipients.yaml` with every existing KeySet as
   a member, which matches who the global epochs are wrapped for.
7. **Creating a space.** Any client with Git access can create a space
   by writing its `recipients.yaml` and first epoch, wrapped for the
   resolved recipients, which must include itself. It does not need
   any existing KEK.
8. **Changing recipients.** Linking a device or creating a recovery
   key adds it to the global members and re-wraps the global key set
   and every `library` space. Revocation removes the key from every
   list the revoking device can read and starts a new epoch in each of
   those key sets. For a space the revoking device cannot read, the
   next member to sync notices a listed member whose KeySet is gone and
   does the same. This last part is an interim strategy.

## Consequences

### Positive

- A client can be given access to one space without access to the
  rest of the library.
- Any client can create a space that no other library member can
  read, using `policy: explicit`.
- gitd can later create its own space for server information without
  holding the library KEK, using `policy: library` with itself as a
  member.
- Access no longer depends on `spec.type`, so new kinds of key holders
  need no new access rules.
- The migration needs no keys and leaves every encrypted object and LFS
  object untouched.

### Negative

- Device link, recovery, and revocation have to re-wrap or rotate every
  space with its own key set they can read, not just the global one.
- A revoked key can read new content in a space the revoking device
  cannot read, until one of that space's members syncs. This interim
  strategy is to be replaced.
- Whether recovery keys are added to `explicit` spaces by default is
  undecided. Without one, losing every member of an `explicit` space
  loses the space.
- Epoch files, key sets, and recipient lists are still unauthenticated
  plaintext. Any Git writer can add a forged epoch to a key set or add
  itself to a recipient list, and key holders outside the library
  widen who can write. Required signed commits, verified per space,
  are left to a later decision.
- A new space is trusted on first use, and so is every space on a
  freshly installed client.
- The migration runner holds every plaintext blob of `main` in memory,
  and this step touches every manifest and pointer.

## References

- ADR-0028: GitDB database format version
- ADR-0038: Key sets and an exact database version
- [Encryption](../../docs/docs/gitdb/encryption.md)
- [Database format version](../../docs/docs/gitdb/database-version.md)
