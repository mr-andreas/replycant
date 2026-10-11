# Webapp

The Replycant webapp keeps a browser-local cache synchronized with the remote Git repository while preserving a defined recovery path for interrupted sync operations.

## Sync Algorithm

The webapp sync loop runs the following phases:

1. `beginSync`: mark UI as syncing and clear stale errors.
2. `readDbSyncedHash`: read `syncedCommitHash` from IndexedDB metadata and treat it as the diff base.
3. `pullWithRebase`: fetch remote branch and fast-forward local checkout (rebase-style behavior).
4. `computeDiffstatPaths`: compute changed `manifests/*.yaml` paths between old DB hash and new head.
5. `buildMutationPlan`: parse old/new blobs per changed path and build deterministic delete/upsert sets.
6. `applyCasTransaction`: in one short IndexedDB readwrite transaction, compare expected old hash and only then apply rows + new hash.
7. `publishSnapshot`: update UI with new objects, commit hash, and change counts.

```mermaid
flowchart TD
  startSync[StartSyncRequest] --> loadPrev[LoadPrevSnapshotAndCacheState]
  loadPrev --> readDbHash[ReadDbSyncedCommitHash]
  readDbHash --> pullRebase[PullWithRebaseAttempt]
  pullRebase -->|success| diffstatPaths[ComputeChangedManifestPaths]
  diffstatPaths --> prepareDelta[BuildMutationPlanOutsideTx]
  prepareDelta --> casTx[RunShortCasReadwriteTx]
  casTx --> casResult{HashStillMatchesExpectedOld}
  casResult -->|yes| applyDelta[ApplyDeleteUpsertRowsAndCommitHash]
  casResult -->|no| staleBail[BailAsStaleAndReloadCommittedCache]
  applyDelta --> publishState[PublishUISnapshotWithChanges]
  staleBail --> publishState
  publishState --> doneState[Done]

  pullRebase -->|conflict| conflictState[SetConflictRecoveryState]
  conflictState --> awaitPerm[AwaitExplicitUserPermission]
  awaitPerm -->|approved| hardReset[HardResetToRemote]
  awaitPerm -->|denied| safeExit[ExitWithoutDestructiveChange]
  hardReset --> pullRebase

  casTx -->|interrupted| recoverBoot[RecoverOnNextBootstrap]
  recoverBoot --> loadPrev
```

### Replycant webapp incremental sync notes

- The compare-and-swap transaction is the IndexedDB equivalent of `UPDATE ... WHERE commithash = oldhash`.
- If two contenders race, one commit hash transition succeeds and the other sees `stale`, skips writes, and reloads committed cache.
- Manifest renames naturally become delete+upsert because path-level diffstat is resolved into old-blob and new-blob keys.
- The expensive work (fetch, diffstat, blob reads, parsing) runs outside the write transaction to avoid long-lived IndexedDB locks.

## Crash Safety

- IndexedDB metadata stores `syncState`, `stagedCommitHash`, and `syncedCommitHash`.
- Sync first writes `syncState=in_progress`, then performs the object-table replacement.
- If the browser crashes before commit, bootstrap recovery clears the in-progress marker and keeps the previously committed cache generation.
- The UI and cache are considered valid only when `syncState=idle` and `syncedCommitHash` points to the revision represented by cached objects.

## Conflict Recovery

- When pull/rebase cannot reconcile local state, sync enters a recoverable conflict state.
- The UI surfaces an explicit `Reset to remote` action.
- Destructive reset is only executed after user permission is granted.

## Setup and Identity Lifecycle

The webapp owns mTLS device identity in the renderer instead of reading `device.key` and `device.crt` from server disk. gitd is reachable only over the tailnet, and only the Electron desktop app runs a tailnet node, so a plain browser tab shows a "desktop app required" screen instead of onboarding.

1. The app asks for a device name, plus a password when OS keyring encryption is unavailable.
2. The app generates a P-256 key pair, self-signed certificate, and age X25519 key, and mints a pairing secret.
3. A paired iOS device scans the QR and authorizes the new device; the sealed pairing record arrives through [Tailnet Pairing](../gitdb/device-onboarding.md#tailnet-pairing).
4. The app opens the record, joins the tailnet, and configures the local proxy with the CA and `https://gitd.replycant.internal:8443`. The proxy derives every backend service from the git origin: `{origin(url)}/lfs`, `/decryptd`, and `/transcoded`, since gitd fronts them all.
5. Private identity material is always AES-GCM encrypted before `localStorage` persistence, wrapped with an OS-keyring-protected device key (`safeStorage`) or, without a keyring, a PBKDF2-derived key from the password.
6. On later launches the app unlocks the identity, rejoins the tailnet, and starts sync.

Existing cleartext identity records are rejected and force a fresh onboarding flow.

The proxy keeps setup only in memory, so each page load replays stored setup config from localStorage before sync begins.

## QR Authorization Flow

After key generation the app shows a QR payload containing device-linking identity fields:

- `pubkey`: SSH-format public key
- `age_pubkey`: age X25519 public key
- `name`: user-provided device name
- `uuid`: generated device identifier
- `pairing_secret`: authenticates the pairing record and addresses its discovery slot

- iOS scans the QR, commits the key to `pubkeys/` in the GitDB repository, and asks gitd to publish the pairing record.
- While the QR is visible, the webapp polls the discovery slot for that record.
- Once the record arrives, the app joins the tailnet and proceeds into clone/sync with transfer progress.

## Request-Time mTLS Forwarding

Browsers cannot perform native mTLS for `isomorphic-git` and object media fetches in this architecture, so the webapp proxy handles upstream TLS:

- Browser attaches base64-encoded client key + client certificate headers on each `/api/git/*`, `/api/lfs/*`, `/api/decryptd/*`, and `/api/transcoded/*` request.
- Browser-provided setup config supplies upstream CA and base URLs to the proxy at runtime.
- Proxy builds per-request HTTPS agent credentials and forwards upstream.
- Credentials are not persisted server-side.

This keeps identity ownership in the browser while preserving mTLS enforcement upstream for every service gitd fronts.

### Session-Scoped Credentials for Direct-Play Video

Direct-play video sets `video.src` and lets the media element issue the request,
and a media element cannot attach custom headers. To authenticate those
requests, the browser posts its identity once to `POST /api/setup/session` after
unlock; the proxy validates it, holds it in memory, and binds it to an
`httpOnly` `SameSite=Strict` session cookie.

Per-request headers always take precedence over session material, so a request
carrying its own identity is never attributed to another browser's session.
Because the store is in memory, a proxy restart drops the session; the
direct-play path re-registers once and retries on a video error rather than
requiring a reload. HLS playback does not need this, since hls.js sets headers
on every segment fetch itself.

See [ADR-0011](https://github.com/mr-andreas/replycant/blob/main/webapp/adr/0011-session-scoped-mtls-material.md).
