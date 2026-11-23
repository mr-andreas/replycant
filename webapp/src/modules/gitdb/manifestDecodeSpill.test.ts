import "fake-indexeddb/auto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ManifestDecodeSpill } from "./manifestDecodeSpill";

describe("ManifestDecodeSpill", () => {
  const spills: ManifestDecodeSpill<string>[] = [];

  afterEach(async () => {
    await Promise.all(spills.splice(0).map((spill) => spill.discard()));
  });

  // One IndexedDB row per manifest made the decode loop slower as the
  // store grew. A chunk is one row, and the items still come back in order
  // when the reader pauses between them.
  it("returns spilled items in order and stores one row per chunk", async () => {
    const spill = new ManifestDecodeSpill<string>("gitdb-manifest-decode-spill-test", 2);
    spills.push(spill);
    await spill.add("a");
    await spill.add("b");
    await spill.add("c");
    expect(await spill.rowCount()).toBe(2);
    const got: string[] = [];
    for await (const item of spill.records()) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      got.push(item);
    }
    expect(got).toEqual(["a", "b", "c"]);
    expect(spill.pendingCount).toBe(0);
  });

  // A decode that fails before the first chunk must still report that
  // failure. Opening IndexedDB here used to replace it with a storage error.
  it("does not touch IndexedDB when nothing was written", async () => {
    const open = vi.spyOn(indexedDB, "open");
    const remove = vi.spyOn(indexedDB, "deleteDatabase");
    const spill = new ManifestDecodeSpill<string>("gitdb-manifest-decode-spill-unused", 2);
    await spill.discard();
    expect(open).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
    open.mockRestore();
    remove.mockRestore();
  });

  it("drops the spill database so a failed decode leaves no staging rows", async () => {
    const spill = new ManifestDecodeSpill<string>("gitdb-manifest-decode-spill-discard", 2);
    await spill.add("a");
    await spill.add("b");
    await spill.discard();
    const databases = (await indexedDB.databases()).map((database) => database.name);
    expect(databases).not.toContain("gitdb-manifest-decode-spill-discard");
  });
});
