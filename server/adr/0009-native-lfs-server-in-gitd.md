# ADR-0009: Native File-Backed LFS Server In gitd

## Status
Accepted

## Context
[ADR-0006](0006-gitd-lfs-mtls-proxy.md) routed LFS through gitd's mTLS gate by
reverse-proxying to `lfs-test-server` with server-side Basic auth and batch
`href` rewriting. That was an interim step until gitd could own object storage
itself.

The proxy added operational surface (a second service, SQLite metadata, static
credentials, response rewriting) without buying anything clients need. Every
consumer already authenticates at gitd, and the only remaining Basic-auth
callers were internal (`decryptd`, `lfs-prereceive`).

## Decision
Replace the proxied `lfs-test-server` with a native, file-backed Git LFS server
running in-process inside gitd.

- Serve the basic-transfer API at `/lfs` after the existing mTLS + `pubkeys/`
  gate. No Basic auth.
- Store objects under `--lfs-dir` as `objects/ab/cd/<rest>` with streamed
  temp-file + rename commits and a per-OID in-flight guard. A second PUT for an
  OID already being written returns `409 Conflict` immediately so clients can
  move on instead of blocking behind a long transfer.
- Advertise batch action `href`s from the live request host so rewrite logic is
  unnecessary.
- Expose a second, read-only plain-HTTP listener (`--lfs-internal-addr`, default
  `:8085`) for compose-network readers such as `decryptd`.
- Have `lfs-prereceive` check the on-disk store via `REPLYCANT_LFS_DIR` instead
  of HTTP.
- Do not implement deletes, locking, or non-basic transfers.

This supersedes ADR-0006. It also amends ADR-0008: the range-probe size fallback
is removed because the native server returns `Content-Length` on HEAD and honors
range end bounds.

## Consequences

### Positive
- One less container and no SQLite/Basic-auth dependency for LFS.
- Batch responses need no href rewriting.
- Range and HEAD behaviour match what decryptd and video seeking require.
- Pre-receive validation becomes a local filesystem check.

### Negative
- Existing `lfs-test-server` content layouts and `lfs.db` are not migrated; alpha
  deployments wipe LFS state or repoint `--lfs-dir` at a compatible tree.
- Internal services must use the new listener URL (`http://gitd:8085/lfs`).
- No client today retries a `409` on PUT: `git-replycant` pre-push fails the
  push, and `replycant-importer` skips that file until a later run.
