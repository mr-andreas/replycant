import { describe, expect, it } from "vitest";
import { cacheRepeatedGitReads } from "./gitReadCache";

// A full resync looks up the same pack directory and gitdir for every
// manifest, and asks for a loose object that this repository never
// wrote. Those repeated lookups are the cost in "Reading manifests".
describe("cacheRepeatedGitReads", () => {
  const looseOid = `${"ab"}${"c".repeat(38)}`;
  const loosePath = `/repo/objects/ab/${"c".repeat(38)}`;

  const createFs = (objectNames: string[]) => {
    const counts = { readdir: 0, stat: 0, lstat: 0, readFile: 0, writeFile: 0 };
    let readdirGate: Promise<void> = Promise.resolve();
    const fs = {
      promises: {
        readdir: async (path: string, opts?: { withFileTypes?: boolean }) => {
          counts.readdir += 1;
          await readdirGate;
          if (opts?.withFileTypes) return [{ name: "typed" }];
          if (path === "/repo/objects") return objectNames.slice();
          if (path === "/repo/objects/pack") return ["pack-real.idx", "pack-real.pack"];
          const error = new Error(`missing ${path}`) as Error & { code: string };
          error.code = "ENOENT";
          throw error;
        },
        stat: async (path: string) => {
          counts.stat += 1;
          return { path, isDirectory: () => true };
        },
        lstat: async (path: string) => {
          counts.lstat += 1;
          return { path, isDirectory: () => true };
        },
        readFile: async (path: string) => {
          counts.readFile += 1;
          return new Uint8Array([path.length]);
        },
        writeFile: async () => {
          counts.writeFile += 1;
        },
      },
    };
    return {
      fs,
      counts,
      holdReaddir: () => {
        readdirGate = new Promise((resolve) => {
          releaseReaddir = resolve;
        });
      },
      releaseReaddir: () => releaseReaddir(),
    };
  };
  let releaseReaddir = (): void => {};

  it("lists a directory once until something is written", async () => {
    const { fs, counts } = createFs(["pack"]);
    cacheRepeatedGitReads(fs);
    await fs.promises.readdir("/repo/objects/pack");
    await fs.promises.readdir("/repo/objects/pack");
    expect(counts.readdir).toBe(1);
    await fs.promises.writeFile();
    await fs.promises.readdir("/repo/objects/pack");
    expect(counts.readdir).toBe(2);
    expect(counts.writeFile).toBe(1);
  });

  it("stats a path once until something is written", async () => {
    const { fs, counts } = createFs(["pack"]);
    cacheRepeatedGitReads(fs);
    await fs.promises.stat("/repo");
    await fs.promises.stat("/repo");
    await fs.promises.lstat("/repo");
    await fs.promises.lstat("/repo");
    expect(counts.stat).toBe(1);
    expect(counts.lstat).toBe(1);
    await fs.promises.writeFile();
    await fs.promises.stat("/repo");
    expect(counts.stat).toBe(2);
  });

  it("does not read a loose object whose shard directory is absent", async () => {
    const { fs, counts } = createFs(["pack", "info"]);
    cacheRepeatedGitReads(fs);
    await expect(fs.promises.readFile(loosePath)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(fs.promises.readFile(loosePath)).rejects.toMatchObject({ code: "ENOENT" });
    expect(counts.readFile).toBe(0);
    expect(counts.readdir).toBe(1);
    expect(looseOid).toHaveLength(40);
  });

  it("still reads a loose object when its shard directory exists", async () => {
    const { fs, counts } = createFs(["pack", "ab"]);
    cacheRepeatedGitReads(fs);
    await expect(fs.promises.readFile(loosePath)).resolves.toEqual(new Uint8Array([loosePath.length]));
    expect(counts.readFile).toBe(1);
  });

  it("reads pack bytes instead of treating them as loose objects", async () => {
    const { fs, counts } = createFs(["pack"]);
    cacheRepeatedGitReads(fs);
    await fs.promises.readFile("/repo/objects/pack/pack-real.pack");
    expect(counts.readFile).toBe(1);
    expect(counts.readdir).toBe(0);
  });

  it("does not cache a directory listing that was requested with file types", async () => {
    const { fs, counts } = createFs(["pack"]);
    cacheRepeatedGitReads(fs);
    await fs.promises.readdir("/repo/objects", { withFileTypes: true });
    await fs.promises.readdir("/repo/objects", { withFileTypes: true });
    expect(counts.readdir).toBe(2);
  });

  it("drops a listing that was still being read when a write started", async () => {
    const { fs, counts, holdReaddir, releaseReaddir } = createFs(["pack"]);
    cacheRepeatedGitReads(fs);
    holdReaddir();
    const first = fs.promises.readdir("/repo/objects");
    await fs.promises.writeFile();
    releaseReaddir();
    await first;
    await fs.promises.readdir("/repo/objects");
    expect(counts.readdir).toBe(2);
  });
});
