# Batch writePointers for progress reporting

## Problem

`writePointers` writes all LFS pointer records (323,941 on a typical
library) in a single IndexedDB transaction. The `await tx.done` blocks
for ~10 seconds while the browser flushes, during which the progress
bar is stuck at 99%.

## Solution

Split the write into batches of 50,000 records. Each batch opens its
own transaction, validates the CAS precondition, writes, and commits.
Between batches an `onProgress(written, total)` callback fires so the
UI can show advancing counts.

### manifestDatabase.ts

```typescript
async writePointers(
  pointersByPath: Map<string, LfsPointerFields>,
  expectedSyncedCommitHash: string,
  onProgress?: (loaded: number, total: number) => void,
): Promise<void> {
  const db = this.requireDb();
  const total = pointersByPath.size;
  const BATCH_SIZE = 50_000;
  let written = 0;
  const entries = [...pointersByPath.entries()];
  for (let offset = 0; offset < entries.length; offset += BATCH_SIZE) {
    const batch = entries.slice(offset, offset + BATCH_SIZE);
    const tx = db.transaction([POINTER_STORE, META_STORE], "readwrite");
    const meta = (await tx.objectStore(META_STORE).get(META_KEY)) as SyncMetaRow | undefined;
    if (meta?.syncedCommitHash !== expectedSyncedCommitHash) {
      tx.abort();
      await tx.done.catch(() => undefined);
      return;
    }
    const pointerStore = tx.objectStore(POINTER_STORE);
    for (const [path, pointer] of batch) {
      pointerStore.put(pointer, path);
    }
    await tx.done;
    written += batch.length;
    onProgress?.(written, total);
  }
}
```

### manifestHydrator.ts (caller)

Wire the callback from the pointer processing section. The unified
progress scale uses `3*N` (read blobs [0..N], DEK unwrap [N..2N],
IDB write [2N..3N]):

```typescript
await this.manifestDb.writePointers(pointers, syncedCommitHash, (loaded, total) => {
  this.emitPointerProgress(2 * N + Math.round((loaded / total) * N), scale);
});
```

### Notes

- Each batch re-checks `syncedCommitHash` so a concurrent sync that
  advances the commit hash will safely abort the remaining batches.
- Materializing the full entries array (`[...pointersByPath.entries()]`)
  costs memory but is needed for random-access slicing. For 323K
  pointers this is ~30-50 MB which is acceptable in the worker.
- The 50K batch size was chosen to give ~6-7 progress updates across
  323K pointers while keeping each transaction commit reasonably sized.
