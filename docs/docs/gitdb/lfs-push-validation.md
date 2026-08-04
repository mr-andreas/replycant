# LFS Push Validation

gitd rejects a push when any Git LFS object referenced by the pushed commits is missing from the configured LFS server.

## Why this exists

This validation prevents the repository from accepting commits that contain valid LFS pointer files but reference unavailable binary content. Without this check, clones and fetches can succeed at the Git layer while media reads fail later.

## How validation works

1. A client performs `git push` against gitd.
2. gitd proxies the request to `git-http-backend`.
3. Git runs a `pre-receive` hook (`lfs-prereceive`) before refs are updated.
4. The hook finds newly introduced commits for the push.
5. The hook scans commit trees for Git LFS pointer blobs and extracts `oid` and `size`.
6. The hook calls the LFS Batch API (`POST /objects/batch`, operation `download`) to verify object existence.
7. If any object is missing, the hook exits non-zero and Git rejects the entire push.

## Failure behavior

When validation fails, the push is rejected atomically. No refs are updated.

The hook writes a rejection message listing missing OIDs, for example:

```text
push rejected: missing LFS objects on the LFS server:
 - 0123456789abcdef...
 - fedcba9876543210...
```

## Edge cases

- Empty or non-LFS pushes pass because no pointer objects are discovered.
- Ref deletions are ignored because they do not introduce new commits.
- If the LFS server is unreachable or returns an error, the push is rejected (fail-safe behavior).
- If `REPLYCANT_LFS_URL` is not configured, validation is skipped for backward compatibility.
