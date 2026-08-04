import { openDB, IDBPDatabase } from "idb";
import type { ManifestKindRegistration, RegisteredManifestRecord } from "./manifestRegistry";
import { deriveManifestStoreName } from "./manifestRegistry";
import type { ManifestRecordUpdate } from "./syncTypes";
import type { LfsPointerFields } from "./encryption";

// Defines the serializable key range so queries can cross the worker boundary via postMessage.
export interface SerializableKeyRange {
  lower?: IDBValidKey;
  upper?: IDBValidKey;
  lowerOpen?: boolean;
  upperOpen?: boolean;
}

// Defines the serializable query request so the app can run arbitrary reads against the
// gitdb-owned database without exposing raw IndexedDB handles or callbacks.
export type ManifestQueryRequest =
  | { type: "get"; key: string }
  | { type: "getAll"; limit?: number }
  | { type: "count"; indexName?: string; range?: SerializableKeyRange }
  | { type: "index"; indexName: string; equals?: IDBValidKey; range?: SerializableKeyRange; direction?: "next" | "prev"; limit?: number }
  | { type: "cursor"; indexName?: string; range?: SerializableKeyRange; direction?: "next" | "prev"; limit?: number; skip?: number };

// Defines the query identity so gitdb can route queries to the correct object store.
export interface ManifestQueryIdentity {
  apiVersion: string;
  kind: string;
}

// Defines one query request against a derived store so app code can read computed rows safely.
export type DerivedStoreQueryRequest =
  | { type: "get"; key: string }
  | { type: "getAll"; limit?: number }
  | { type: "count" }
  | { type: "cursor"; range?: SerializableKeyRange; direction?: "next" | "prev"; limit?: number };

// Describes the source-side cursor row exposed to derived rebuild and mutation hooks.
export interface DerivedManifestCursorValue {
  primaryKey: IDBValidKey;
  key: IDBValidKey;
  value: RegisteredManifestRecord;
}

// Describes the source-side key cursor row exposed to derived hooks when values are not needed.
export interface DerivedManifestKeyCursorValue {
  primaryKey: IDBValidKey;
  key: IDBValidKey;
}

// Provides read-only access to registered manifest stores while derived hooks run inside a write transaction.
export interface DerivedStoreManifestAccess {
  openCursor(
    identity: ManifestQueryIdentity,
    options?: { indexName?: string; range?: SerializableKeyRange; direction?: "next" | "prev" },
  ): AsyncIterable<DerivedManifestCursorValue>;
  openKeyCursor(
    identity: ManifestQueryIdentity,
    options?: { indexName?: string; range?: SerializableKeyRange; direction?: "next" | "prev" },
  ): AsyncIterable<DerivedManifestKeyCursorValue>;
  count(
    identity: ManifestQueryIdentity,
    options?: { indexName?: string; range?: SerializableKeyRange },
  ): Promise<number>;
}

// Provides read-write access to one derived store while hooks execute in the parent cache transaction.
export interface DerivedStoreDerivedAccess {
  get(key: IDBValidKey): Promise<unknown>;
  put(value: unknown): Promise<void>;
  delete(key: IDBValidKey): Promise<void>;
  getAll(limit?: number): Promise<unknown[]>;
}

// Provides one scoped context so derived hooks can read manifests and write computed rows atomically.
export interface DerivedStoreContext {
  manifests: DerivedStoreManifestAccess;
  derived: DerivedStoreDerivedAccess;
}

// Defines one app-owned derived store and the hooks gitdb executes to keep it
// synchronized with the manifest snapshot.
//
// Firefox transaction contract for both hooks: implementations may only await IDB
// requests (cursor walks, get/put/delete). Awaiting any non-IDB promise (fetch,
// setTimeout, postMessage, decryption, message-channel handoff) inside a hook will
// drop the surrounding transaction in Firefox and cause TransactionInactiveError on
// the next IDB call. See ADR 0008.
//
// rebuild runs inside the final commit transaction of a full rehydration, after
// every manifest chunk has landed, so it observes the complete snapshot. applyMutation
// runs inside the single CAS-guarded transaction of an incremental update and shares
// the same Firefox-safety contract.
export interface DerivedStoreDefinition {
  name: string;
  keyPath: string;
  rebuild(context: DerivedStoreContext): Promise<void>;
  applyMutation(context: DerivedStoreContext, mutation: ManifestDatabaseMutation): Promise<void>;
}

// Provides stable store identity for sync metadata state.
const META_STORE = "gitdb_sync_meta";
const POINTER_STORE = "lfs_pointers";
const META_KEY = "state";
const SCHEMA_VERSION = 6;

// Bounds how many manifest records each full-rehydration chunk transaction writes.
// Sized to amortize transaction overhead while keeping each transaction short enough
// to satisfy Firefox's strict IDB lifecycle (see ADR 0008): a transaction must never
// span a non-IDB await, so streamed pipelines write in many small transactions and
// rely on a final commit marker for consumer-visible atomicity.
export const FULL_REHYDRATION_CHUNK_SIZE = 2000;

// Describes one persisted sync metadata row that keeps CAS and recovery state durable.
interface SyncMetaRow {
  key: "state";
  syncState: "idle" | "in_progress";
  stagedCommitHash: string | null;
  syncedCommitHash: string | null;
  lastSyncAt: string | null;
}

// Describes the incremental mutation applied between two commits.
export interface ManifestDatabaseMutation {
  added: RegisteredManifestRecord[];
  updated: ManifestRecordUpdate[];
  removed: RegisteredManifestRecord[];
}

// Describes pointer mutations to apply alongside manifest changes.
export interface PointerMutation {
  added: Map<string, LfsPointerFields>;
  removed: string[];
}

// Describes CAS preconditions for applying incremental transitions safely.
export interface IncrementalApplyOptions {
  expectedSyncedCommitHash: string | null;
  nextSyncedCommitHash: string;
  mutation: ManifestDatabaseMutation;
  pointerMutation?: PointerMutation;
}

// Describes the result of one CAS mutation attempt.
export interface IncrementalApplyResult {
  outcome: "applied" | "stale";
}

// Describes fault-injection knobs for store replacement tests that validate interrupted-write recovery.
export interface ReplaceCacheOptions {
  crashAfterMarkInProgress?: boolean;
  crashDuringCommit?: boolean;
}

// Reconstructs an IDBKeyRange from a serializable representation so queries work across worker RPC.
const toIDBKeyRange = (range: SerializableKeyRange): IDBKeyRange => {
  if (range.lower !== undefined && range.upper !== undefined) {
    return IDBKeyRange.bound(range.lower, range.upper, range.lowerOpen, range.upperOpen);
  }
  if (range.lower !== undefined) {
    return IDBKeyRange.lowerBound(range.lower, range.lowerOpen);
  }
  if (range.upper !== undefined) {
    return IDBKeyRange.upperBound(range.upper, range.upperOpen);
  }
  throw new Error("SerializableKeyRange must specify at least lower or upper.");
};

// Emits database diagnostics so storage-side CAS and replacement behavior remains observable.
const logDbDebug = (event: string, fields: Record<string, unknown>): void => {
  const duration = typeof fields.durationMs === "number" ? `${(fields.durationMs / 1000).toFixed(2)}s ` : "";
  console.debug(`[gitdb-db] ${duration}${event}`, fields);
};

const nowMs = (): number => Date.now();

type DerivedHookStore = {
  index: (name: string) => {
    openCursor: (query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection) => Promise<DerivedHookCursor | null>;
    openKeyCursor: (query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection) => Promise<DerivedHookKeyCursor | null>;
    count: (query?: IDBValidKey | IDBKeyRange | null) => Promise<number>;
  };
  openCursor: (query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection) => Promise<DerivedHookCursor | null>;
  openKeyCursor: (query?: IDBValidKey | IDBKeyRange | null, direction?: IDBCursorDirection) => Promise<DerivedHookKeyCursor | null>;
  get: (key: IDBValidKey) => Promise<unknown>;
  put: (value: unknown) => Promise<unknown>;
  delete: (key: IDBValidKey) => Promise<void>;
  getAll: (query?: IDBValidKey | IDBKeyRange | null, count?: number) => Promise<unknown[]>;
  count: (query?: IDBValidKey | IDBKeyRange | null) => Promise<number>;
};

type DerivedHookCursor = {
  primaryKey: IDBValidKey;
  key: IDBValidKey;
  value: unknown;
  continue: () => Promise<DerivedHookCursor | null>;
};

type DerivedHookKeyCursor = {
  primaryKey: IDBValidKey;
  key: IDBValidKey;
  continue: () => Promise<DerivedHookKeyCursor | null>;
};

type DerivedHookTransaction = {
  objectStore: (name: string) => DerivedHookStore;
};

// Owns the single gitdb IndexedDB database with manifest and derived object stores created from registrations.
// Replaces both GitdbRegistryAdapter and GitdbEntityRegistry with one unified persistence layer
// that handles sync-cache operations, CAS mutations, recovery, and arbitrary queries.
export class ManifestDatabase {
  private db: IDBPDatabase | null = null;
  private readonly registrations: ManifestKindRegistration[];
  private readonly derivedStores: DerivedStoreDefinition[];
  private readonly derivedStoreNames: Set<string>;
  private readonly registrationKeys: Set<string>;
  private readonly databaseName: string;
  private readonly fullRehydrationChunkSize: number;

  // Accepts manifest registrations plus optional derived-store hooks so cache writes
  // and computed rows stay atomic. The optional fullRehydrationChunkSize lets tests
  // exercise the multi-transaction chunked path without staging thousands of records.
  constructor(
    registrations: ManifestKindRegistration[],
    derivedStoresOrDatabaseName: DerivedStoreDefinition[] | string = [],
    databaseName: string = "gitdb-manifests-v1",
    fullRehydrationChunkSize: number = FULL_REHYDRATION_CHUNK_SIZE,
  ) {
    this.registrations = registrations;
    const derivedStores = Array.isArray(derivedStoresOrDatabaseName) ? derivedStoresOrDatabaseName : [];
    this.derivedStores = derivedStores;
    this.derivedStoreNames = new Set(derivedStores.map((definition) => definition.name));
    this.registrationKeys = new Set(registrations.map((registration) => `${registration.apiVersion}::${registration.kind}`));
    this.databaseName = typeof derivedStoresOrDatabaseName === "string" ? derivedStoresOrDatabaseName : databaseName;
    if (fullRehydrationChunkSize < 1) {
      throw new Error("fullRehydrationChunkSize must be >= 1");
    }
    this.fullRehydrationChunkSize = fullRehydrationChunkSize;
  }

  async initialize(): Promise<void> {
    if (this.db) return;
    const registrations = this.registrations;
    const derivedStores = this.derivedStores;
    this.db = await openDB(this.databaseName, SCHEMA_VERSION, {
      // Recreates cache schema on any version change because gitdb data is fully reconstructible from git history.
      upgrade(database) {
        for (const storeName of Array.from(database.objectStoreNames)) {
          database.deleteObjectStore(storeName);
        }
        database.createObjectStore(META_STORE, { keyPath: "key" });
        database.createObjectStore(POINTER_STORE);
        for (const reg of registrations) {
          const storeName = deriveManifestStoreName(reg.apiVersion, reg.kind);
          const store = database.createObjectStore(storeName, { keyPath: "key" });
          for (const index of reg.indexes ?? []) {
            store.createIndex(index.name, index.fieldPath, {
              unique: false,
              multiEntry: Boolean(index.multiEntry),
            });
          }
        }
        for (const definition of derivedStores) {
          database.createObjectStore(definition.name, { keyPath: definition.keyPath });
        }
      },
    });
  }

  async close(): Promise<void> {
    this.db?.close();
    this.db = null;
  }

  private requireDb(): IDBPDatabase {
    if (!this.db) throw new Error("ManifestDatabase.initialize must be called first.");
    return this.db;
  }

  private storeNames(): string[] {
    return this.registrations.map((r) => deriveManifestStoreName(r.apiVersion, r.kind));
  }

  // Lists all derived store names so write transactions can include computed stores atomically.
  private derivedStoreNameList(): string[] {
    return this.derivedStores.map((definition) => definition.name);
  }

  // Resolves one manifest identity to its backing store and guards against unregistered identities.
  private resolveManifestStoreName(identity: ManifestQueryIdentity): string {
    const registrationKey = `${identity.apiVersion}::${identity.kind}`;
    if (!this.registrationKeys.has(registrationKey)) {
      throw new Error(`Manifest kind is not registered: ${registrationKey}`);
    }
    return deriveManifestStoreName(identity.apiVersion, identity.kind);
  }

  // Verifies a derived-store name before reads/writes so callers cannot access arbitrary object stores.
  private assertKnownDerivedStore(storeName: string): void {
    if (!this.derivedStoreNames.has(storeName)) {
      throw new Error(`Derived store is not registered: ${storeName}`);
    }
  }

  // Reads current sync metadata row or returns a safe default when state has not been initialized.
  private async readMetaState(): Promise<SyncMetaRow> {
    const db = this.requireDb();
    const row = await db.get(META_STORE, META_KEY);
    return (row as SyncMetaRow | undefined) ?? {
      key: "state",
      syncState: "idle",
      stagedCommitHash: null,
      syncedCommitHash: null,
      lastSyncAt: null,
    };
  }

  // Clears stale in-progress metadata so sync bootstrap never continues from ambiguous write state.
  async recoverInterruptedCacheUpdate(): Promise<boolean> {
    const db = this.requireDb();
    const state = await this.readMetaState();
    if (state.syncState !== "in_progress") return false;
    await db.put(META_STORE, {
      ...state,
      syncState: "idle",
      stagedCommitHash: null,
    });
    return true;
  }

  async readSyncedCommitHash(): Promise<string | null> {
    const state = await this.readMetaState();
    return state.syncedCommitHash;
  }

  // Creates one scoped context so derived hooks can read manifest rows and write computed rows in one transaction.
  private buildDerivedStoreContext(tx: DerivedHookTransaction, derivedStoreName: string): DerivedStoreContext {
    const createManifestSource = (identity: ManifestQueryIdentity, indexName?: string) => {
      const manifestStoreName = this.resolveManifestStoreName(identity);
      const store = tx.objectStore(manifestStoreName);
      return indexName ? store.index(indexName) : store;
    };
    const createManifestStore = (identity: ManifestQueryIdentity): DerivedHookStore => {
      const manifestStoreName = this.resolveManifestStoreName(identity);
      return tx.objectStore(manifestStoreName);
    };
    return {
      manifests: {
        openCursor: async function* (
          identity: ManifestQueryIdentity,
          options?: { indexName?: string; range?: SerializableKeyRange; direction?: "next" | "prev" },
        ): AsyncIterable<DerivedManifestCursorValue> {
          const source = createManifestSource(identity, options?.indexName);
          const range = options?.range ? toIDBKeyRange(options.range) : undefined;
          let cursor = await source.openCursor(range, options?.direction ?? "next");
          while (cursor) {
            yield {
              primaryKey: cursor.primaryKey,
              key: cursor.key,
              value: cursor.value as RegisteredManifestRecord,
            };
            cursor = await cursor.continue();
          }
        },
        openKeyCursor: async function* (
          identity: ManifestQueryIdentity,
          options?: { indexName?: string; range?: SerializableKeyRange; direction?: "next" | "prev" },
        ): AsyncIterable<DerivedManifestKeyCursorValue> {
          const source = createManifestSource(identity, options?.indexName);
          const range = options?.range ? toIDBKeyRange(options.range) : undefined;
          let cursor = await source.openKeyCursor(range, options?.direction ?? "next");
          while (cursor) {
            yield {
              primaryKey: cursor.primaryKey,
              key: cursor.key,
            };
            cursor = await cursor.continue();
          }
        },
        count: async (
          identity: ManifestQueryIdentity,
          options?: { indexName?: string; range?: SerializableKeyRange },
        ): Promise<number> => {
          const range = options?.range ? toIDBKeyRange(options.range) : undefined;
          const store = createManifestStore(identity);
          if (!options?.indexName) {
            return store.count(range);
          }
          return store.index(options.indexName).count(range);
        },
      },
      derived: {
        get: async (key: IDBValidKey): Promise<unknown> => tx.objectStore(derivedStoreName).get(key),
        put: async (value: unknown): Promise<void> => {
          await tx.objectStore(derivedStoreName).put(value);
        },
        delete: async (key: IDBValidKey): Promise<void> => {
          await tx.objectStore(derivedStoreName).delete(key);
        },
        getAll: async (limit?: number): Promise<unknown[]> =>
          tx.objectStore(derivedStoreName).getAll(undefined, limit) as Promise<unknown[]>,
      },
    };
  }

  // Replaces full cache snapshot atomically so one committed revision is always rendered.
  async replaceCache(
    recordsByKind: Map<string, RegisteredManifestRecord[]>,
    syncedCommitHash: string,
    options: ReplaceCacheOptions = {},
    pointersByPath?: Map<string, LfsPointerFields>,
  ): Promise<void> {
    const db = this.requireDb();
    const startedAtMs = nowMs();
    const currentMeta = await this.readMetaState();

    await db.put(META_STORE, {
      ...currentMeta,
      syncState: "in_progress",
      stagedCommitHash: syncedCommitHash,
    });

    if (options.crashAfterMarkInProgress) {
      throw new Error("Simulated crash after in-progress marker was persisted.");
    }

    const stores = this.storeNames();
    const derivedStoreNames = this.derivedStoreNameList();
    const tx = db.transaction([...stores, ...derivedStoreNames, POINTER_STORE, META_STORE], "readwrite");

    for (const storeName of stores) {
      await tx.objectStore(storeName).clear();
    }

    await tx.objectStore(POINTER_STORE).clear();

    for (const [_kind, records] of recordsByKind) {
      for (const record of records) {
        const storeName = deriveManifestStoreName(record.apiVersion, record.kind);
        await tx.objectStore(storeName).put(record);
      }
    }

    if (pointersByPath) {
      const pointerStore = tx.objectStore(POINTER_STORE);
      for (const [path, pointer] of pointersByPath) {
        await pointerStore.put(pointer, path);
      }
    }

    for (const derivedStore of this.derivedStores) {
      await tx.objectStore(derivedStore.name).clear();
      const context = this.buildDerivedStoreContext(tx as DerivedHookTransaction, derivedStore.name);
      await derivedStore.rebuild(context);
    }

    if (options.crashDuringCommit) {
      tx.abort();
      await tx.done.catch(() => undefined);
      throw new Error("Simulated crash while committing cache transaction.");
    }

    await tx.objectStore(META_STORE).put({
      key: "state",
      syncState: "idle",
      stagedCommitHash: null,
      syncedCommitHash,
      lastSyncAt: new Date().toISOString(),
    } as SyncMetaRow);

    await tx.done;

    let totalRecords = 0;
    for (const records of recordsByKind.values()) {
      totalRecords += records.length;
    }
    logDbDebug("replace-cache-complete", {
      syncedCommitHash,
      totalRecords,
      pointerCount: pointersByPath?.size ?? 0,
      durationMs: nowMs() - startedAtMs,
    });
  }

  // Replaces full cache from a streaming pipeline so records flow into IDB as they
  // are decoded, keeping peak memory bounded by chunk size rather than total record
  // count. Splits work across many short transactions because Firefox auto-commits
  // an IDB transaction across any await on a non-IDB promise (the streaming pipeline
  // awaits git reads, decryption, and bounded-channel handoffs between writes). The
  // consumer-visible atomicity guarantee comes from the syncState / stagedCommitHash
  // meta row: readers gate on syncedCommitHash and never observe partial state.
  // See ADR 0008 for the full rationale and recovery model.
  async replaceCacheStreamed(
    records: AsyncIterable<RegisteredManifestRecord>,
    syncedCommitHash: string,
    pointersByPath?: Map<string, LfsPointerFields>,
  ): Promise<{ totalRecords: number }> {
    const startedAtMs = nowMs();

    await this.beginFullRehydration(syncedCommitHash);

    let totalRecords = 0;
    let buffer: RegisteredManifestRecord[] = [];
    const flushBuffer = async (): Promise<void> => {
      if (buffer.length === 0) return;
      const chunk = buffer;
      buffer = [];
      await this.writeFullRehydrationChunk(chunk);
    };

    for await (const record of records) {
      buffer.push(record);
      totalRecords += 1;
      if (buffer.length >= this.fullRehydrationChunkSize) {
        await flushBuffer();
      }
    }
    await flushBuffer();

    if (pointersByPath && pointersByPath.size > 0) {
      await this.writeFullRehydrationPointers(pointersByPath);
    }

    await this.commitFullRehydration(syncedCommitHash);

    logDbDebug("replace-cache-streamed-complete", {
      syncedCommitHash,
      totalRecords,
      pointerCount: pointersByPath?.size ?? 0,
      chunkSize: this.fullRehydrationChunkSize,
      durationMs: nowMs() - startedAtMs,
    });
    return { totalRecords };
  }

  // Marks the rehydration as in-progress and wipes manifest and pointer stores in
  // one short transaction. Holding clear() inside a small, isolated transaction
  // avoids any cross-await dependency on streaming sources further down the pipeline.
  private async beginFullRehydration(syncedCommitHash: string): Promise<void> {
    const db = this.requireDb();
    const currentMeta = await this.readMetaState();
    const stores = this.storeNames();
    const tx = db.transaction([...stores, POINTER_STORE, META_STORE], "readwrite");
    await tx.objectStore(META_STORE).put({
      ...currentMeta,
      syncState: "in_progress",
      stagedCommitHash: syncedCommitHash,
    });
    for (const storeName of stores) {
      await tx.objectStore(storeName).clear();
    }
    await tx.objectStore(POINTER_STORE).clear();
    await tx.done;
  }

  // Writes one in-memory chunk of records in a single short transaction. The for-loop
  // does not await between put() calls, so every IDB request is queued on the
  // transaction before control returns to the event loop, keeping the transaction
  // active in Firefox until tx.done.
  private async writeFullRehydrationChunk(chunk: RegisteredManifestRecord[]): Promise<void> {
    if (chunk.length === 0) return;
    const db = this.requireDb();
    const touchedStores = new Set<string>();
    for (const record of chunk) {
      touchedStores.add(deriveManifestStoreName(record.apiVersion, record.kind));
    }
    const tx = db.transaction([...touchedStores], "readwrite");
    for (const record of chunk) {
      const storeName = deriveManifestStoreName(record.apiVersion, record.kind);
      tx.objectStore(storeName).put(record);
    }
    await tx.done;
  }

  // Writes pointer rows in their own short transaction after manifest chunks land.
  // Pointers are typically much smaller than the manifest set and arrive fully
  // materialized, so a single transaction is both correct and Firefox-safe.
  private async writeFullRehydrationPointers(
    pointersByPath: Map<string, LfsPointerFields>,
  ): Promise<void> {
    const db = this.requireDb();
    const tx = db.transaction(POINTER_STORE, "readwrite");
    const pointerStore = tx.objectStore(POINTER_STORE);
    for (const [path, pointer] of pointersByPath) {
      pointerStore.put(pointer, path);
    }
    await tx.done;
  }

  // Flips the commit marker and rebuilds derived stores over the now-complete
  // manifest snapshot. Derived hook implementations may only await IDB requests
  // (cursor walks, get/put/delete), which keeps this final transaction alive in
  // Firefox; awaiting a non-IDB promise from a derived hook would break the contract.
  private async commitFullRehydration(syncedCommitHash: string): Promise<void> {
    const db = this.requireDb();
    const stores = this.storeNames();
    const derivedStoreNames = this.derivedStoreNameList();
    const tx = db.transaction([...stores, ...derivedStoreNames, META_STORE], "readwrite");
    for (const derivedStore of this.derivedStores) {
      await tx.objectStore(derivedStore.name).clear();
      const context = this.buildDerivedStoreContext(tx as DerivedHookTransaction, derivedStore.name);
      await derivedStore.rebuild(context);
    }
    await tx.objectStore(META_STORE).put({
      key: "state",
      syncState: "idle",
      stagedCommitHash: null,
      syncedCommitHash,
      lastSyncAt: new Date().toISOString(),
    } as SyncMetaRow);
    await tx.done;
  }

  // Writes LFS pointer entries into the existing cache after the streamed manifest pipeline finishes,
  // keeping pointer writes separate so the main pipeline transaction stays lean.
  async writePointers(
    pointersByPath: Map<string, LfsPointerFields>,
    expectedSyncedCommitHash: string,
  ): Promise<void> {
    const db = this.requireDb();
    const tx = db.transaction([POINTER_STORE, META_STORE], "readwrite");
    const meta = (await tx.objectStore(META_STORE).get(META_KEY)) as SyncMetaRow | undefined;
    if (meta?.syncedCommitHash !== expectedSyncedCommitHash) {
      tx.abort();
      await tx.done.catch(() => undefined);
      return;
    }
    const pointerStore = tx.objectStore(POINTER_STORE);
    for (const [path, pointer] of pointersByPath) {
      pointerStore.put(pointer, path);
    }
    await tx.done;
  }

  // Applies key-scoped mutations only when the metadata CAS precondition still
  // matches the expected commit hash. Holds one IDB transaction across the entire
  // apply because incremental updates are race-sensitive (a concurrent sync attempt
  // may try to advance from the same expected hash) and must commit atomically.
  //
  // This single-transaction design is safe in Firefox only because the caller
  // provides a fully-materialized ManifestDatabaseMutation in memory and every
  // await inside this method is on an IDB request: Firefox keeps the transaction
  // active across IDB request callbacks but auto-commits across awaits on
  // non-IDB promises. The streaming full-rehydration path cannot share this design
  // because its records arrive from an async pipeline (git reads, decryption,
  // channel handoffs); it uses chunked transactions instead. See ADR 0008.
  async applyIncrementalWithCas(options: IncrementalApplyOptions): Promise<IncrementalApplyResult> {
    const db = this.requireDb();
    const stores = this.storeNames();
    const derivedStoreNames = this.derivedStoreNameList();
    const tx = db.transaction([...stores, ...derivedStoreNames, POINTER_STORE, META_STORE], "readwrite");
    const metaStore = tx.objectStore(META_STORE);
    const currentMeta = (await metaStore.get(META_KEY)) as SyncMetaRow | undefined;
    const currentSyncedHash = currentMeta?.syncedCommitHash ?? null;

    if (currentSyncedHash !== options.expectedSyncedCommitHash) {
      tx.abort();
      await tx.done.catch(() => undefined);
      return { outcome: "stale" };
    }

    await metaStore.put({
      key: "state",
      syncState: "in_progress",
      stagedCommitHash: options.nextSyncedCommitHash,
      syncedCommitHash: currentSyncedHash,
      lastSyncAt: currentMeta?.lastSyncAt ?? null,
    } as SyncMetaRow);

    for (const record of options.mutation.removed) {
      const storeName = deriveManifestStoreName(record.apiVersion, record.kind);
      await tx.objectStore(storeName).delete(record.key);
    }

    for (const record of options.mutation.added) {
      const storeName = deriveManifestStoreName(record.apiVersion, record.kind);
      await tx.objectStore(storeName).put(record);
    }

    for (const update of options.mutation.updated) {
      const record = update.current;
      const storeName = deriveManifestStoreName(record.apiVersion, record.kind);
      await tx.objectStore(storeName).put(record);
    }

    if (options.pointerMutation) {
      const pointerStore = tx.objectStore(POINTER_STORE);
      for (const path of options.pointerMutation.removed) {
        await pointerStore.delete(path);
      }
      for (const [path, pointer] of options.pointerMutation.added) {
        await pointerStore.put(pointer, path);
      }
    }

    for (const derivedStore of this.derivedStores) {
      const context = this.buildDerivedStoreContext(tx as DerivedHookTransaction, derivedStore.name);
      await derivedStore.applyMutation(context, options.mutation);
    }

    await metaStore.put({
      key: "state",
      syncState: "idle",
      stagedCommitHash: null,
      syncedCommitHash: options.nextSyncedCommitHash,
      lastSyncAt: new Date().toISOString(),
    } as SyncMetaRow);

    await tx.done;
    return { outcome: "applied" };
  }

  // Short-circuits on the first non-empty store so bootstrap can gate without loading all records.
  async hasAnyRecords(): Promise<boolean> {
    const db = this.requireDb();
    for (const reg of this.registrations) {
      const storeName = deriveManifestStoreName(reg.apiVersion, reg.kind);
      const count = await db.count(storeName);
      if (count > 0) return true;
    }
    return false;
  }

  // Loads current snapshot payload from all registered stores.
  async loadCache(): Promise<{ recordsByKind: Map<string, RegisteredManifestRecord[]>; syncedCommitHash: string | null }> {
    const db = this.requireDb();
    const recordsByKind = new Map<string, RegisteredManifestRecord[]>();
    const state = await this.readMetaState();

    for (const reg of this.registrations) {
      const storeName = deriveManifestStoreName(reg.apiVersion, reg.kind);
      const rows = await db.getAll(storeName);
      recordsByKind.set(`${reg.apiVersion}::${reg.kind}`, rows as RegisteredManifestRecord[]);
    }

    return { recordsByKind, syncedCommitHash: state.syncedCommitHash };
  }

  // Executes a serializable query against one registered manifest store.
  async query(
    identity: ManifestQueryIdentity,
    request: ManifestQueryRequest,
  ): Promise<RegisteredManifestRecord[] | number> {
    const db = this.requireDb();
    const storeName = this.resolveManifestStoreName(identity);
    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);

    switch (request.type) {
      case "get": {
        const row = await store.get(request.key);
        return row ? [row as RegisteredManifestRecord] : [];
      }
      case "getAll": {
        const rows = await store.getAll(undefined, request.limit);
        return rows as RegisteredManifestRecord[];
      }
      case "count": {
        const keyRange = request.range ? toIDBKeyRange(request.range) : undefined;
        if (request.indexName) {
          return store.index(request.indexName).count(keyRange);
        }
        return store.count(keyRange);
      }
      case "index": {
        const index = store.index(request.indexName);
        if (request.equals !== undefined) {
          const rows = await index.getAll(request.equals, request.limit);
          return rows as RegisteredManifestRecord[];
        }
        if (request.range) {
          const keyRange = toIDBKeyRange(request.range);
          if (request.direction && request.direction !== "next") {
            const results: RegisteredManifestRecord[] = [];
            let cursor = await index.openCursor(keyRange, request.direction);
            while (cursor && (!request.limit || results.length < request.limit)) {
              results.push(cursor.value as RegisteredManifestRecord);
              cursor = await cursor.continue();
            }
            return results;
          }
          const rows = await index.getAll(keyRange, request.limit);
          return rows as RegisteredManifestRecord[];
        }
        const rows = await index.getAll(undefined, request.limit);
        return rows as RegisteredManifestRecord[];
      }
      case "cursor": {
        const results: RegisteredManifestRecord[] = [];
        const keyRange = request.range ? toIDBKeyRange(request.range) : undefined;
        const source = request.indexName ? store.index(request.indexName) : store;
        let cursor = await source.openCursor(keyRange, request.direction ?? "next");
        let remainingSkip = Math.max(0, request.skip ?? 0);
        while (cursor && remainingSkip > 0) {
          cursor = await cursor.continue();
          remainingSkip -= 1;
        }
        while (cursor && (!request.limit || results.length < request.limit)) {
          results.push(cursor.value as RegisteredManifestRecord);
          cursor = await cursor.continue();
        }
        return results;
      }
    }
  }

  // Resolves LFS pointer metadata for a batch of binary paths so consumers can look up encryption data.
  async queryPointers(paths: string[]): Promise<Map<string, LfsPointerFields>> {
    const db = this.requireDb();
    const tx = db.transaction(POINTER_STORE, "readonly");
    const store = tx.objectStore(POINTER_STORE);
    const result = new Map<string, LfsPointerFields>();
    for (const path of paths) {
      const row = await store.get(path);
      if (row) {
        result.set(path, row as LfsPointerFields);
      }
    }
    return result;
  }

  // Executes a derived-store read query while validating store identity against registered definitions.
  async queryDerived<T = unknown>(storeName: string, request: DerivedStoreQueryRequest): Promise<T[] | number> {
    this.assertKnownDerivedStore(storeName);
    const db = this.requireDb();
    const tx = db.transaction(storeName, "readonly");
    const store = tx.objectStore(storeName);

    switch (request.type) {
      case "get": {
        const row = await store.get(request.key);
        return row ? [row as T] : [];
      }
      case "getAll": {
        const rows = await store.getAll(undefined, request.limit);
        return rows as T[];
      }
      case "count": {
        return store.count();
      }
      case "cursor": {
        const results: T[] = [];
        const keyRange = request.range ? toIDBKeyRange(request.range) : undefined;
        let cursor = await store.openCursor(keyRange, request.direction ?? "next");
        while (cursor && (!request.limit || results.length < request.limit)) {
          results.push(cursor.value as T);
          cursor = await cursor.continue();
        }
        return results;
      }
    }
  }
}
