import { describe, expect, it, vi } from "vitest";
import { CommitTransitionApplier } from "./commitTransitionApplier";
import type { ChangedPath } from "./treeDiffer";

const POINTER_TEXT = [
  "version https://git-lfs.github.com/spec/v1",
  "oid sha256:abc123",
  "size 42",
].join("\n");

// Builds typed changed-path entries so tests stay focused on mutation outcomes.
const changedPath = (
  path: string,
  oldOid: string | null,
  newOid: string | null,
): ChangedPath => ({ path, oldOid, newOid });

// Creates an applier with narrow mocks so tests can assert transition decisions in isolation.
const createApplier = () => {
  const log = vi.fn();
  const applyIncrementalWithCas = vi.fn().mockResolvedValue({ outcome: "applied" });
  const listChangedManifestPaths = vi.fn().mockResolvedValue([]);
  const listChangedBinaryPaths = vi.fn().mockResolvedValue([]);
  const readManifestRecordAtBlobOid = vi.fn().mockResolvedValue(null);
  const readManifestRecordAtCommitOrNull = vi.fn().mockResolvedValue(null);
  const readBlobByOidOrNull = vi.fn().mockResolvedValue(null);
  const unwrapDeksForPointers = vi.fn().mockResolvedValue(undefined);
  const refreshKekCacheState = vi.fn().mockResolvedValue(undefined);
  const applier = new CommitTransitionApplier({
    manifestDb: {
      applyIncrementalWithCas,
    } as never,
    treeDiffer: {
      listChangedManifestPaths,
      listChangedBinaryPaths,
    } as never,
    manifestBlobReader: {
      readManifestRecordAtBlobOid,
      readManifestRecordAtCommitOrNull,
      readBlobByOidOrNull,
      unwrapDeksForPointers,
      refreshKekCacheState,
    } as never,
    log,
  });
  return {
    applier,
    log,
    applyIncrementalWithCas,
    listChangedManifestPaths,
    listChangedBinaryPaths,
    readManifestRecordAtBlobOid,
    readManifestRecordAtCommitOrNull,
    readBlobByOidOrNull,
    unwrapDeksForPointers,
    refreshKekCacheState,
  };
};

describe("CommitTransitionApplier", () => {
  it("treats unchanged commit transitions as applied without hydration", async () => {
    const { applier } = createApplier();
    const result = await applier.applyCommitTransitionToCache("abc123", "abc123");
    expect(result).toEqual({ outcome: "applied" });
  });

  it("requests full hydration when no previous synced hash exists", async () => {
    const { applier } = createApplier();
    const result = await applier.applyCommitTransitionToCache(null, "next123");
    expect(result).toEqual({ outcome: "needs_full_hydration" });
  });

  it("builds incremental mutation by changed blob oids and skips missing sides", async () => {
    const {
      applier,
      applyIncrementalWithCas,
      listChangedManifestPaths,
      listChangedBinaryPaths,
      readManifestRecordAtBlobOid,
      readManifestRecordAtCommitOrNull,
      readBlobByOidOrNull,
      unwrapDeksForPointers,
      refreshKekCacheState,
    } = createApplier();
    const oldCommitHash = "old123";
    const newCommitHash = "new456";

    listChangedManifestPaths.mockResolvedValue([
      changedPath("manifests/dev/media.replycant.com/v1alpha1/Original/added.yaml", null, "manifest-added"),
      changedPath("manifests/dev/media.replycant.com/v1alpha1/Original/removed.yaml", "manifest-removed", null),
      changedPath("manifests/dev/media.replycant.com/v1alpha1/Original/updated.yaml", "manifest-prev", "manifest-next"),
      changedPath("manifests/dev/media.replycant.com/v1alpha1/Original/key-changed.yaml", "manifest-old-key", "manifest-new-key"),
    ]);
    listChangedBinaryPaths.mockResolvedValue([
      changedPath("binary/dev/file-added.bin", null, "pointer-added"),
      changedPath("binary/dev/file-removed.bin", "pointer-removed", null),
    ]);

    readManifestRecordAtBlobOid.mockImplementation(async (commitHash: string, blobOid: string) => {
      const keyPrefix = commitHash === oldCommitHash ? "old" : "new";
      if (blobOid === "manifest-added") {
        return { key: `${keyPrefix}-added`, kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: {} };
      }
      if (blobOid === "manifest-removed") {
        return { key: `${keyPrefix}-removed`, kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: {} };
      }
      if (blobOid === "manifest-prev") {
        return { key: "same-key", kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: { rev: "old" } };
      }
      if (blobOid === "manifest-next") {
        return { key: "same-key", kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: { rev: "new" } };
      }
      if (blobOid === "manifest-old-key") {
        return { key: "old-key", kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: {} };
      }
      if (blobOid === "manifest-new-key") {
        return { key: "new-key", kind: "Original", apiVersion: "media.replycant.com/v1alpha1", manifest: {} };
      }
      return null;
    });
    readBlobByOidOrNull.mockImplementation(async (oid: string) => {
      if (oid === "pointer-added") {
        return new TextEncoder().encode(POINTER_TEXT);
      }
      return null;
    });

    const result = await applier.tryApplyIncrementalCommitTransitionToCache(oldCommitHash, newCommitHash);

    expect(result.outcome).toBe("applied");
    expect(refreshKekCacheState).toHaveBeenCalledTimes(2);
    expect(readManifestRecordAtBlobOid).toHaveBeenCalledTimes(6);
    expect(readManifestRecordAtBlobOid).not.toHaveBeenCalledWith(oldCommitHash, "manifest-added", expect.any(String));
    expect(readManifestRecordAtBlobOid).not.toHaveBeenCalledWith(newCommitHash, "manifest-removed", expect.any(String));
    expect(readManifestRecordAtCommitOrNull).not.toHaveBeenCalled();
    expect(readBlobByOidOrNull).toHaveBeenCalledTimes(1);
    expect(readBlobByOidOrNull).toHaveBeenCalledWith("pointer-added");
    expect(unwrapDeksForPointers).toHaveBeenCalledTimes(1);

    const applyCall = applyIncrementalWithCas.mock.calls[0]?.[0];
    expect(applyCall.mutation.added).toHaveLength(2);
    expect(applyCall.mutation.removed).toHaveLength(2);
    expect(applyCall.mutation.updated).toHaveLength(1);
    expect(applyCall.pointerMutation.added.size).toBe(1);
    expect(applyCall.pointerMutation.removed).toEqual(["binary/dev/file-removed.bin"]);
  });
});
