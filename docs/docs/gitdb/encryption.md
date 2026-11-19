# Encryption

GitDB treats the server as untrusted storage. Every manifest and binary is
encrypted on the client before it leaves the device, so a server compromise
exposes only opaque blobs. [mTLS](./authentication.md) protects data in
transit; the encryption described here protects it at rest.

## How the keys fit together

Three layers of keys protect the data:

1. Each device has an **age key** (X25519). It unwraps KEKs.
2. The **KEK** (key encryption key) is a random AES-256 key. It encrypts
   manifests directly and wraps the per-binary DEKs. The library has a
   global KEK, and an [encryption space](#encryption-spaces) can have its
   own.
3. Each binary has its own **DEK** (data encryption key), also AES-256. It
   encrypts that one binary.

```mermaid
flowchart LR
    Device["Device age key"] -->|unwraps| KEK
    KEK -->|encrypts| Manifests
    KEK -->|unwraps| DEK["Per-binary DEK"]
    DEK -->|encrypts| Binary["Binary chunks"]
```

Each KEK is wrapped for an explicit list of
[recipients](#recipient-lists), and only those key holders can decrypt
what it protects. Adding a device only re-wraps the small KEK files, and
revoking one only creates new KEKs. Neither touches the encrypted objects.

Each device holds two key pairs, both stored in the iOS Keychain or, on
desktop, in encrypted localStorage (protected by the OS keyring or a
password):

| Key | Algorithm | Used for |
|-----|-----------|----------|
| Identity key | ECDSA P-256 | [mTLS authentication](./authentication.md) |
| Encryption key | age (X25519) | Unwrapping the KEK |

Both public keys live in one plaintext file per key holder:

```text
pubkeys/
  iphone-16e.yaml
  kitchen-ipad-<uuid>.yaml
```

```yaml
apiVersion: gitdb.replycant.com/v1alpha1
kind: KeySet
metadata:
  name: iphone-16e          # must equal the file name
spec:
  type: device              # device, recovery, or app; descriptive only
  mtlsPublicKey: ecdsa-sha2-nistp256 AAAA...
  agePublicKey: age1...
  displayName:              # optional; only a device with the KEK can read it
    kekEpoch: 2
    ciphertext: <base64 nonce || ciphertext || tag>
```

The file is plaintext because gitd authorizes a device before any of them
has unwrapped the KEK. `displayName` is the exception: it is AES-256-GCM
sealed with the KEK for `kekEpoch`, and the additional data is
`replycant-keyset-display-name-v1` followed by `metadata.name`. That
binding means a rewritten file cannot move a name onto another key set.
When the field is missing, or this device cannot open it, readers show
`metadata.name`. Key sets stay outside `encryptionspaces/` so that tree
can stay uniformly encrypted. See [Manifests](./manifests.md).

| `spec.type` | Holder |
|-------------|--------|
| `device` | A phone or computer |
| `recovery` | A backup credential |
| `app` | Another client, such as an upload app |

`spec.type` is descriptive only and has no technical effect. Apps use it
to decide where a key holder appears in Settings. It never decides what a
key holder can decrypt, which KEKs are wrapped for it, or whether gitd
lets it connect. Access comes only from [recipient lists](#recipient-lists).

[age](https://github.com/FiloSottile/age) is used instead of GPG or ECIES
with P-256 because it has no configuration, key servers, or web of trust,
and a public key is one ~62-character string. It is also small enough to
implement natively with Apple CryptoKit (Curve25519 and ChaCha20-Poly1305)
and the `age-encryption` npm package, without shelling out to a CLI.

## Key epochs

The KEK is a random 32-byte key, stored in the repository encrypted with age
for every recipient. Each KEK is an epoch:

```text
gitdb/
  version              # database format version, for example "3"
encryption/
  current              # active epoch number, for example "2"
  epochs/
    1.age              # KEK epoch 1, age-encrypted for all recipients
    2.age              # KEK epoch 2, after a key rotation
  recipients.yaml      # who the epochs are wrapped for
```

`gitdb/version` pins the repository layout and crypto handling, and clients
refuse any other value. See [Database format version](./database-version.md).
Manifest schemas are versioned separately, by each resource's `apiVersion`.

This is the global key set. A space with
[its own key set](#encryption-spaces) has the same `current`, `epochs/`,
and `recipients.yaml` layout under its own folder.

The first device creates epoch 1 for its own age key and writes
`recipients.yaml` with itself as the only member. After that, epochs
change only when key holders come and go:

| Event | Action |
|-------|--------|
| Device added | Add it to the global members; re-wrap every epoch of the global key set and of every `library` space for the new age key |
| Device removed | Remove it from every recipient list; new KEK for the remaining recipients in each key set it was in; bump `current` |
| Key rotation | Same as device removal, for one key set |

Revoking a key in a space the revoking device cannot read follows an
[interim strategy](#revoking-in-spaces-you-cannot-read).

New objects always use the current epoch. A removed device keeps the old
KEKs from Git history and can still read old objects, but it cannot read
anything added afterwards. Adding a device re-wraps every epoch, so the new
device can read the whole history. The app flows for these events are in
[Device onboarding](./device-onboarding.md).

## Encryption spaces

An encryption space is a self-contained encrypted part of the library.
Every manifest and binary belongs to exactly one space, and only holders of
that space's key set can read it. This lets a client write into one space
without being able to read any other: an upload app, for example, can add
media to its own space without seeing the rest of the library.

```text
encryptionspaces/
  iphone-16e-<uuid>/                  # uses the global key set
    manifests/{apiVersion}/{kind}/{shard}.yaml
    binary/{apiVersion}/{kind}/{shard}
  upload-app-<uuid>/                  # has its own key set
    manifests/...
    binary/...
    encryption/
      current
      epochs/
        1.age
      recipients.yaml
```

A file's space is the folder it lives in. Manifests do not record it, so a
manifest cannot claim a space other than the one it is stored in. Each
device writes its own media into a space named after the device, but a
space is not tied to a device.

### Choosing the key set

A space that contains `encryption/current` has its own key set. Any other
space uses the global key set in the top-level `encryption/` folder:

```mermaid
flowchart LR
    P["File in encryptionspaces/S/"] --> Q{"S/encryption/current exists?"}
    Q -->|yes| Own["Key set of S"]
    Q -->|no| Global["Global key set"]
    Own --> K["KEK for the epoch in the header or pointer"]
    Global --> K
```

The manifest envelope and LFS pointer still carry only an epoch number. The
key set comes from the file's path, so the same epoch number in two key
sets names two unrelated KEKs.

### Only the space's own KEK

A client decrypts every object in a space with a KEK from that space's key
set, and nothing else:

- a space with its own key set never falls back to the global KEK
- a space never uses another space's KEK
- a client never tries several KEKs until one works

An object that does not open with its space's key set is an error. Without
this rule, anyone holding some KEK could plant objects in a space they
cannot read. For example, an upload app could write a manifest sealed with
its own KEK into a device's space, and a client that tried every KEK it
knows would accept it as that device's photo.

### Recipient lists

Every key set has a `recipients.yaml` that says who its epochs are wrapped
for. Members are KeySet names from `pubkeys/`, and each KeySet supplies its
age public key. A key holder maps to any number of spaces, zero included,
through the lists that name it.

The global list names the library's members:

```yaml title="encryption/recipients.yaml"
members:
  - iphone-16e-<uuid>
  - home-safe-<uuid>
```

A space's own list also has a policy:

```yaml title="encryptionspaces/upload-app-<uuid>/encryption/recipients.yaml"
policy: library
members:
  - upload-app-<uuid>
```

| Key set | Wrapped for |
|---------|-------------|
| Global | Its `members` |
| Space with `policy: library` | Every global member, plus its own `members` |
| Space with `policy: explicit` | Only its own `members` |
| Space without its own key set | The global recipients, because it uses the global key set |

A `library` space follows the library: linking a new device into the
library also gives it every `library` space. An `explicit` space is
private to its members, and other devices in the library cannot read it.
A key holder that is not a global member never holds the global KEK, so it
can write only into spaces with their own key set.

### Who can read a space

| Use | Policy | Members |
|-----|--------|---------|
| Upload app that may write but not read the library | `library` | The app |
| Private album on one phone | `explicit` | That phone |
| gitd's server information (planned) | `library` | gitd |

A recovery key reads an `explicit` space only if it is listed there.

The KeySet of a key holder that is not a global member has no
`displayName`, because that field is sealed with the global KEK. Readers
show `metadata.name` instead.

### Creating a space

Any client with Git access can create a new space without being able to
read any existing one:

1. Choose a policy and members. The creator must be one of the resolved
   recipients.
2. Generate a random 32-byte KEK.
3. Wrap it with age for every resolved recipient.
4. Commit `encryptionspaces/{space}/encryption/current` as `1`, together
   with `encryption/epochs/1.age`, `encryption/recipients.yaml`, the
   creator's key set if it is new, and the space's first objects.

Creating a space needs only the recipient lists and the public keys in
`pubkeys/`, which are plaintext.

Planned use: during bootstrap, once the first commit arrives, gitd creates
its own space with `policy: library` and itself as a member, where it
stores information about the server. Every current and future library
member can read it, and gitd never holds the global KEK.

### Revoking in spaces you cannot read

A revoking device removes the key from every recipient list it can read,
and starts a new epoch in each of those key sets. It cannot do this for an
`explicit` space it is not a member of. Instead, the next member of that
space to sync notices a listed member whose KeySet is gone, removes it, and
starts a new epoch. Until then, the revoked key can still read new content
in that space.

:::note Interim strategy
This strategy leaves a window in which a revoked key can read new content.
It will be replaced.
:::

### Integrity checks

Each client records, per space, whether the space uses the global key set
or its own. A space gaining or losing `encryption/` after the client has
seen it is refused as tampering. Otherwise a writer could give an
inherited space a key set it controls. A space the client has never seen is
trusted on first use, as the global key set is.

A client opens only the key sets whose resolved recipients include its own
KeySet. It never opens any other space, and does not check it.

In a key set the client is a recipient of, improper encryption never
happens in normal operation. It signals a serious bug or an adversary, so
it stops the client. These all count:

- an object that does not open with its space's key set
- an epoch missing from that key set
- a plaintext object, or a pointer without `x-replycant-*` metadata
- a space switching between the global key set and its own
- an epoch that this client, although listed, cannot unwrap
- a missing or invalid `recipients.yaml`

On any of these, the client stops syncing and writes nothing. It shows a
persistent error naming the space and path. The apps keep running so the
error stays visible, and command-line tools exit with an error.

:::warning Forged epochs and recipient lists
Epoch files, key sets, and recipient lists are unauthenticated plaintext.
Anyone who can push can add a new epoch with a KEK of their choosing to
any key set and bump `current`. Clients then encrypt new objects with that
KEK and accept objects sealed with it. A writer can also add itself to a
recipient list, and the next legitimate re-wrap includes it. Git commits
are not signed, so clients cannot tell who made such a change.
:::

### Examples

A space with no `encryption/` folder uses the global key set. A device's
media is the usual case. The device's KeySet is `pubkeys/phone-<uuid>.yaml`,
and that name is a member of `encryption/recipients.yaml`, so every library
member can read the space.

```text
encryptionspaces/phone-<uuid>/
  manifests/media.replycant.com/v1alpha1/Original/e8/8f/3b2a-1234-5678-9abc-def012345678-l0-001.yaml
  binary/media.replycant.com/v1alpha1/Original/e8/8f/3b2a-1234-5678-9abc-def012345678-l0-001
```

The two prefix directories are the first four characters of
`metadata.name`. See [Manifests](./manifests.md#storage-path-convention).
The manifest file in Git is the encrypted envelope, and `kek-epoch` names
an epoch of the global key set. Decrypted, it is an
[Original](../protocol/original.md):

```yaml title="decrypted plaintext of the manifest above"
apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: e88f3b2a-1234-5678-9abc-def012345678-l0-001
spec:
  id: E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001
  sha256: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
  mediaType: photo
  mimeType: image/jpeg
```

The file under `binary/` is an LFS pointer, not the media. See
[Media storage](./media-storage.md#binary-lfs-storage).

A client that is not a library member keeps its own key set. With
`policy: library`, every global member can read the space, and the client
holds only that space's KEK.

```text
pubkeys/service.yaml
encryptionspaces/service/
  encryption/
    current                  # 1
    epochs/1.age             # this space's KEK, wrapped for the recipients below
    recipients.yaml
  manifests/<apiVersion>/<kind>/<shard>.yaml
```

```yaml title="pubkeys/service.yaml"
apiVersion: gitdb.replycant.com/v1alpha1
kind: KeySet
metadata:
  name: service
spec:
  type: app                  # descriptive only; not a global member
  mtlsPublicKey: ecdsa-sha2-nistp256 AAAA...
  agePublicKey: age1...
```

```yaml title="encryptionspaces/service/encryption/recipients.yaml"
policy: library
members:
  - service
```

`service` is absent from `encryption/recipients.yaml`, so it cannot open
`phone-<uuid>/`. A manifest under `encryptionspaces/service/manifests/` is
the same encrypted envelope, and `kek-epoch` names an epoch of this space.

## Manifests

Manifests are encrypted directly with the current KEK of their space's key
set, using AES-256-GCM.
They are small and numerous and never shared one at a time, so a
per-manifest DEK would add cost without benefit.

The encrypted file keeps its `.yaml` name and
[path](./manifests.md), but its content becomes:

```text
REPLYCANT-ENC-V1
kek-epoch: 2
---
<12-byte nonce><ciphertext><16-byte GCM tag>
```

The plaintext is the original YAML, the nonce is random per file, and
`kek-epoch` names the epoch, within the space's key set, to decrypt with.

Clients fail closed. They reject any manifest without the `REPLYCANT-ENC-V1`
envelope and any LFS pointer without `x-replycant-*` metadata. There is no
plaintext fallback, so a hostile server that strips encryption cannot make
clients parse attacker-controlled data.

For development, a Git clean/smudge filter encrypts on commit and decrypts on
checkout, so standard Git tooling works. Smudge rejects plaintext repository
objects. The one exception is `textconv` (path-argument smudge), which shows
already-decrypted worktree files in `git diff` and never writes back.

## Binaries

Each binary gets a random DEK. The binary is split into fixed-size chunks,
each encrypted and authenticated with AES-256-GCM, and the wrapped DEK goes
into the [LFS pointer](#lfs-pointer).

### Why each binary has its own key

- **Blast radius**: a leaked DEK exposes one file, not the library.
- **Nonce safety**: chunk nonces come from the chunk index. Each DEK
  encrypts one file, so no key and nonce pair is ever reused.
- **Sharing**: a single DEK can grant access to one object without exposing
  the KEK.
- **Rotation**: rotating the KEK never re-encrypts binaries.

DEKs are random rather than derived from the content. Convergent encryption
would let the LFS server deduplicate identical files, but clients never
upload the same binary twice: they deduplicate by plaintext SHA-256 before
any upload. Random keys are the safer choice and lose nothing.

### Chunk format

The encrypted binary on the LFS server is a headerless sequence of chunks:

```text
[chunk 0: ciphertext | 16-byte GCM tag]
[chunk 1: ciphertext | 16-byte GCM tag]
...
[chunk N-1: ciphertext | 16-byte GCM tag]
```

Nonces are derived, never stored. Each chunk is sealed with:

- **nonce**: `0x00000000 || uint64BE(index)`
- **AAD**: `"replycant-lfs-chunk-v1" || uint64BE(index) || uint8(isLast)`

Binding the index and the last-chunk flag into the AAD means tampering,
reordering, and truncation all fail authentication. Wrapped DEKs use the AAD
`"replycant-dek-wrap-v1" || uint64BE(kekEpoch)`.

| Property | Value |
|----------|-------|
| Chunk size | 64 KiB (65,536 bytes) of plaintext |
| Per-chunk overhead | 16 bytes (GCM tag) |
| Overhead for a 1 GB file | ~256 KB (~0.025%) |

Chunk size is a compile-time constant, not pointer metadata. The last chunk
may be shorter, and empty plaintext produces zero chunks. Chunked GCM was
chosen over single-block or CTR mode because it gives both per-chunk
authentication and random access.

### LFS pointer

The standard LFS pointer carries two extra fields:

```text
version https://git-lfs.github.com/spec/v1
oid sha256:4d7a2146...
size 4821033
x-replycant-kek-epoch 2
x-replycant-wrapped-dek <base64>
```

| Field | Meaning |
|-------|---------|
| `oid` / `size` | SHA-256 and size of the **encrypted** content |
| `x-replycant-kek-epoch` | KEK epoch that wrapped the DEK |
| `x-replycant-wrapped-dek` | The DEK, wrapped with the KEK |

The DEK lives in the pointer rather than the manifest because the pointer
already owns retrieval, so it owns decryption too. The
[manifest's `sha256`](./media-storage.md) stays the hash of the
**plaintext**, for verification after decryption.

### Reading a binary

1. Read `x-replycant-kek-epoch` and `x-replycant-wrapped-dek` from the LFS
   pointer.
2. Unwrap the KEK for that epoch, from the key set of the pointer's space,
   with the device's age private key.
3. Unwrap the DEK with the KEK and the epoch-bound AAD.
4. Download the chunks you need from LFS.
5. Decrypt each chunk with the DEK, deriving its nonce and AAD from the
   chunk index and last-chunk flag.
6. Concatenate the plaintext. For a whole file, verify its SHA-256 against
   the manifest's `sha256`.

Video transcoding and HLS streaming read byte ranges without decrypting the
whole file. To read N bytes at offset O, fetch chunks
`O / 65536` through `(O + N - 1) / 65536`. Each encrypted chunk is
`65536 + 16` bytes, so the range starts at `start_chunk * 65552`, and HTTP
range requests fetch only those chunks. At worst, reading one byte decrypts
one 64 KiB chunk.

## Recovery keys

Recovery keys are an emergency path for when every normal device key is
lost. They are the same key set as a device, with `spec.type: recovery`,
and they live in the same `pubkeys/` directory:

```text
pubkeys/
  my-phone-<uuid>.yaml
  home-safe-<uuid>.yaml
```

The recovery file's `mtlsPublicKey` is a P-256 SSH-form public key, so
gitd authorizes it with the same matching logic as a device. Settings
lists it with the recovery keys, not with the devices. Creating a recovery
key adds it to the global members and re-wraps like a
[device link](#key-epochs). It reads an `explicit` space only if it is
listed there.

### Bundle format

The private halves are exported as an encrypted JSON envelope:

- KDF: `PBKDF2-HMAC-SHA256`, 600k iterations
- Cipher: `AES-256-GCM`
- Plaintext: the recovery P-256 PEM key, the recovery age private key, the
  pinned CA SHA-256 hash, and the deployment's `headscale_url`

The app exports the envelope as a QR code containing the raw JSON, or as a
deep link `replycant://recover?v=1&d=<base64url envelope>`. Neither needs a
hosted web domain.

Recovery runs only on a fresh install. The app decrypts the bundle, joins
the library with the recovery identity, and adds a new device key set to
every recipient list that names the recovery key. It re-wraps the epochs of
each of those key sets for the new device age key, and then switches to
that new device identity. See
[Recovery onboarding path](./device-onboarding.md#recovery-onboarding-path)
for the full flow and the optional deep link parameters.

### Manual recovery

If the app cannot run recovery, you can process the bundle by hand:

1. Decode the envelope JSON from the QR code or from the deep link's `d`
   parameter.
2. Derive the AES key with the bundle's KDF parameters
   (`PBKDF2-HMAC-SHA256`).
3. Decrypt the envelope ciphertext (`AES-256-GCM`) to get the plaintext JSON.
4. Connect to `headscale_url`, take the CA from the certificate chain hsproxy
   presents, and check that its hash matches `ca_sha256`.
5. Use `p256_private_key` for temporary mTLS Git access.
6. Add a new device key set in `pubkeys/`. Add its name to the global
   `encryption/recipients.yaml` and to every space's `recipients.yaml` that
   lists the recovery key.
7. Use `age_private_key` to re-wrap, for the new device's age key, the
   epoch files of the global key set, of every `library` space, and of
   every space whose list you changed.

This is why the bundle is plain JSON and carries both private keys.
