import { describe, expect, it, vi } from "vitest";
import { ManifestHydrator } from "./manifestHydrator";
import type { TreeDiffer } from "./treeDiffer";
import type { ManifestDatabase } from "./manifestDatabase";
import type { ManifestBlobReader } from "./manifestBlobReader";

describe("ManifestHydrator", () => {
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
});
