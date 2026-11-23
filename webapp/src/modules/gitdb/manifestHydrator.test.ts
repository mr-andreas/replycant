import "fake-indexeddb/auto";
import { afterEach, describe, expect, it, vi } from "vitest";
import git from "isomorphic-git";
import { ManifestHydrator } from "./manifestHydrator";
import type { TreeDiffer } from "./treeDiffer";
import type { ManifestDatabase } from "./manifestDatabase";
import type { ManifestBlobReader } from "./manifestBlobReader";
import type { RegisteredManifestRecord } from "./manifestRegistry";

describe("ManifestHydrator", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  const createHydrator = (treeDiffer: Partial<TreeDiffer>, manifestDb: Partial<ManifestDatabase>) =>
    new ManifestHydrator({
      fs: { promises: {} } as never,
      gitdir: "/repo",
      treeDiffer: treeDiffer as TreeDiffer,
      manifestDb: manifestDb as ManifestDatabase,
      manifestBlobReader: {} as ManifestBlobReader,
      registeredKindDirectories: () => ["media.replycant.com/v1alpha1/Original"],
      emitTreeWalkProgress: () => {},
      emitKekRefreshProgress: () => {},
      emitManifestReadProgress: () => {},
      emitPointerProgress: () => {},
      log: () => {},
      cache: {},
    });

  it("does not wipe the cache when the manifests tree is unreadable", async () => {
    const replaceCacheStreamed = vi.fn();
    const hydrator = createHydrator(
      {
        discoverDeviceSpaces: vi.fn().mockResolvedValue({
          status: "unreadable",
          cause: new Error("repo not fetch-ready"),
        }),
      },
      { replaceCacheStreamed },
    );

    await expect(hydrator.streamManifestsToCache("commit", "commit", 1)).rejects.toThrow(
      /could not read manifests tree/,
    );
    expect(replaceCacheStreamed).not.toHaveBeenCalled();
  });

  it("replaces the cache when the manifests tree is provably absent", async () => {
    const replaceCacheStreamed = vi.fn().mockResolvedValue({ totalRecords: 0 });
    const hydrator = createHydrator(
      {
        discoverDeviceSpaces: vi.fn().mockResolvedValue({
          status: "ok",
          deviceSpaces: [],
        }),
      },
      { replaceCacheStreamed },
    );

    await expect(hydrator.streamManifestsToCache("commit", "commit", 1)).resolves.toMatchObject({
      totalRecords: 0,
    });
    expect(replaceCacheStreamed).toHaveBeenCalled();
  });

  // The read loop must not keep the parsed record. The cache write parses
  // the saved YAML again, so a later manifest is not slowed by the objects
  // already decoded.
  it("parses a manifest again when the cache is replaced", async () => {
    const yaml = "kind: Original\nname: photo\n";
    const parsed: RegisteredManifestRecord[] = [];
    const decodeYamlToRecord = vi.fn(() => {
      const record: RegisteredManifestRecord = {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        key: `photo-${parsed.length}`,
        manifest: {},
      };
      parsed.push(record);
      return record;
    });
    const replaceCacheStreamed = vi.fn(async (records: AsyncIterable<RegisteredManifestRecord>) => {
      const got: RegisteredManifestRecord[] = [];
      for await (const record of records) got.push(record);
      expect(got).toEqual([parsed[1]]);
      return { totalRecords: got.length };
    });
    vi.spyOn(git, "readBlob").mockResolvedValue({ blob: new Uint8Array([1]), oid: "abc" } as never);
    const hydrator = new ManifestHydrator({
      fs: { promises: {} } as never,
      gitdir: "/repo",
      treeDiffer: {
        discoverDeviceSpaces: vi.fn().mockResolvedValue({ status: "ok", deviceSpaces: ["album"] }),
        readTreeAtCommitPathOrNull: vi.fn(async (_commit: string, path: string) =>
          path.includes("/binary/") ? null : { tree: [] },
        ),
        collectBlobEntriesFromTree: vi.fn(async (
          _tree: unknown,
          _base: string,
          entries: { oid: string; path: string }[],
          extension?: string,
        ) => {
          if (extension === ".yaml") {
            entries.push({
              oid: "abc",
              path: "encryptionspaces/album/manifests/media.replycant.com/v1alpha1/Original/ab/cd/photo.yaml",
            });
          }
        }),
      } as unknown as TreeDiffer,
      manifestDb: { replaceCacheStreamed } as unknown as ManifestDatabase,
      manifestBlobReader: {
        refreshKekCacheState: vi.fn(async () => {}),
        keySetRoot: vi.fn(async () => "encryption"),
        decodeManifestBlobToYaml: vi.fn(async () => yaml),
        decodeYamlToRecord,
        inferExpectedKindFromPath: vi.fn(() => ({
          apiVersion: "media.replycant.com/v1alpha1",
          kind: "Original",
        })),
        unwrapDeksForPointers: vi.fn(async () => {}),
      } as unknown as ManifestBlobReader,
      registeredKindDirectories: () => ["media.replycant.com/v1alpha1/Original"],
      emitTreeWalkProgress: () => {},
      emitKekRefreshProgress: () => {},
      emitManifestReadProgress: () => {},
      emitPointerProgress: () => {},
      log: () => {},
      cache: {},
    });

    await hydrator.streamManifestsToCache("commit", "commit", 1);
    expect(decodeYamlToRecord).toHaveBeenCalledTimes(2);
  });
});
