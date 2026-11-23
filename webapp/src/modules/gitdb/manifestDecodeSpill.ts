import { deleteDB, openDB } from "idb";
import type { IDBPDatabase } from "idb";

const STORE = "records";

// A full library is hundreds of thousands of manifests. Keeping every
// decoded record in the JS heap makes later manifests slower and slower
// as the collector runs. Each chunk is one row, so the store stays small,
// and the timeline never opens this database. It is deleted whether the
// decode succeeds or not. The visible library is replaced only after
// every manifest has opened.
export class ManifestDecodeSpill<T> {
  private dbPromise: Promise<IDBPDatabase> | null = null;
  private pending: T[] = [];
  private stored = 0;

  constructor(
    private readonly databaseName: string,
    private readonly chunkSize = 500,
  ) {}

  // Items accepted so far, including the chunk not yet written.
  get length(): number {
    return this.stored + this.pending.length;
  }

  // The chunk still in memory. Tests use this to prove a flush happened.
  get pendingCount(): number {
    return this.pending.length;
  }

  async add(item: T): Promise<void> {
    this.pending.push(item);
    if (this.pending.length >= this.chunkSize) await this.flush();
  }

  // How many rows are on disk. A row is one chunk, not one item.
  async rowCount(): Promise<number> {
    await this.flush();
    if (this.stored === 0) return 0;
    const db = await this.database();
    return db.count(STORE);
  }

  // Pages the rows so the cursor transaction is closed before the
  // caller awaits. A cursor held open across the cache write would
  // be committed by IndexedDB and the rest of the library would be lost.
  async *records(): AsyncGenerator<T> {
    await this.flush();
    if (this.stored === 0) return;
    const db = await this.database();
    let after: IDBValidKey | undefined;
    for (;;) {
      const tx = db.transaction(STORE);
      const cursor = await tx.store.openCursor(
        after === undefined ? undefined : IDBKeyRange.lowerBound(after, true),
      );
      const chunk = cursor ? cursor.value as T[] : null;
      if (cursor) after = cursor.key;
      await tx.done;
      if (!chunk) return;
      for (const item of chunk) yield item;
    }
  }

  // Nothing was written, so there is no database to remove. Deleting
  // one anyway would replace the decode error that the caller needs.
  async discard(): Promise<void> {
    this.pending = [];
    this.stored = 0;
    if (!this.dbPromise) return;
    const db = await this.dbPromise;
    db.close();
    this.dbPromise = null;
    await deleteDB(this.databaseName);
  }

  private async flush(): Promise<void> {
    if (this.pending.length === 0) return;
    const chunk = this.pending;
    this.pending = [];
    const db = await this.database();
    const tx = db.transaction(STORE, "readwrite");
    tx.store.add(chunk);
    await tx.done;
    this.stored += chunk.length;
  }

  // A leftover database from a crashed decode would prepend its rows
  // to this run, so it is removed before the first write.
  private database(): Promise<IDBPDatabase> {
    if (!this.dbPromise) {
      this.dbPromise = deleteDB(this.databaseName).then(() => openDB(this.databaseName, 1, {
        upgrade(db) {
          db.createObjectStore(STORE, { autoIncrement: true });
        },
      }));
    }
    return this.dbPromise;
  }
}
