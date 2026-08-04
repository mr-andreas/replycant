import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import { deriveEntityStoreName, GitdbEntityRegistry } from "./registry";

// Produces a valid manifest-like entity row for schema registration and persistence tests.
const makeOriginalRow = (name: string) => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  metadata: { name },
  spec: {
    id: name,
    takenAt: "2026-03-08T12:00:00Z",
  },
});

describe("GitdbEntityRegistry", () => {
  // Resets entity database so each test can validate deterministic schema behavior in isolation.
  beforeEach(async () => {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.deleteDatabase("gitdb-entities-test");
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
      request.onblocked = () => resolve();
    });
  });

  it("derives stable store names from apiVersion and kind", () => {
    expect(
      deriveEntityStoreName({
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
      }),
    ).toBe("media_replycant_com_v1alpha1_Original");
  });

  it("persists rows with metadata.name as primary key", async () => {
    const registry = new GitdbEntityRegistry();
    try {
      registry.registerEntity({
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        indexes: [{ name: "byTakenAt", fieldPath: "spec.takenAt" }],
      });
      await registry.initialize("gitdb-entities-test");
      const row = makeOriginalRow("a3cf41279-d3a6-40eb-a815-e572d9b22173-l0-001");
      await registry.upsertEntity(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        row,
        "manifests/a3/cf/41279-d3a6-40eb-a815-e572d9b22173-l0-001.yaml",
      );
      const found = await registry.queryEntity(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { key: "a3cf41279-d3a6-40eb-a815-e572d9b22173-l0-001" },
      );
      expect(found).toHaveLength(1);
      expect(found[0]?.metadata.name).toBe("a3cf41279-d3a6-40eb-a815-e572d9b22173-l0-001");
    } finally {
      registry.close();
    }
  });

  it("rejects rows when metadata.name does not match yaml filename", async () => {
    const registry = new GitdbEntityRegistry();
    try {
      registry.registerEntity({
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
      });
      await registry.initialize("gitdb-entities-test");
      await expect(
        registry.upsertEntity(
          { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
          makeOriginalRow("different-name"),
          "manifests/so/ur/ce-name.yaml",
        ),
      ).rejects.toThrow("metadata.name must match YAML filename");
    } finally {
      registry.close();
    }
  });
});
