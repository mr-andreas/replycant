import { describe, expect, it } from "vitest";
import { deriveManifestStoreName, ManifestRegistry } from "./manifestRegistry";

// Minimal decoded manifest shape for registration tests.
interface TestOriginal {
  id: string;
  name: string;
}

// Provides a deterministic decoder so tests can verify registry decode/key dispatch.
const testOriginalRegistration = {
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  decode: (rawYaml: string): TestOriginal | null => {
    const idMatch = rawYaml.match(/id:\s*(.+)/);
    const nameMatch = rawYaml.match(/name:\s*(.+)/);
    if (!idMatch || !nameMatch) return null;
    return { id: idMatch[1].trim(), name: nameMatch[1].trim() };
  },
  primaryKey: (decoded: TestOriginal) => decoded.id,
};

describe("deriveManifestStoreName", () => {
  it("produces deterministic store names from apiVersion and kind", () => {
    expect(deriveManifestStoreName("media.replycant.com/v1alpha1", "Original"))
      .toBe("manifests_media_replycant_com_v1alpha1_Original");
  });

  it("normalizes special characters", () => {
    expect(deriveManifestStoreName("some.api/v2", "My-Kind"))
      .toBe("manifests_some_api_v2_My_Kind");
  });
});

describe("ManifestRegistry", () => {
  it("registers and retrieves a manifest kind", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);

    expect(registry.has("media.replycant.com/v1alpha1", "Original")).toBe(true);
    expect(registry.has("media.replycant.com/v1alpha1", "Unknown")).toBe(false);
  });

  it("rejects duplicate registrations", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    expect(() => registry.register(testOriginalRegistration)).toThrow("already registered");
  });

  it("decodes YAML using the registered decoder", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);

    const yaml = `apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: test-001
spec:
  id: photo-123
  name: test-001`;

    const result = registry.decodeYaml(yaml);
    expect(result).not.toBeNull();
    expect(result!.apiVersion).toBe("media.replycant.com/v1alpha1");
    expect(result!.kind).toBe("Original");
    expect((result!.decoded as TestOriginal).id).toBe("photo-123");
  });

  it("returns null for unregistered kinds", () => {
    const registry = new ManifestRegistry();
    const yaml = `apiVersion: media.replycant.com/v1alpha1
kind: Unknown
spec: {}`;
    expect(registry.decodeYaml(yaml)).toBeNull();
  });

  it("resolves primary key from decoded manifest", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    const decoded: TestOriginal = { id: "photo-123", name: "test" };
    expect(registry.resolveKey("media.replycant.com/v1alpha1", "Original", decoded)).toBe("photo-123");
  });

  it("throws when resolving key for unregistered kind", () => {
    const registry = new ManifestRegistry();
    expect(() => registry.resolveKey("unknown/v1", "Nope", {})).toThrow("No registration");
  });

  it("lists all registrations", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    registry.register({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "ThumbnailSet",
      decode: () => null,
      primaryKey: () => "",
    });
    expect(registry.allRegistrations()).toHaveLength(2);
  });

  it("returns registered kind directories", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    registry.register({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "ThumbnailSet",
      decode: () => null,
      primaryKey: () => "",
    });
    const dirs = registry.registeredKindDirectories();
    expect(dirs).toHaveLength(2);
    expect(dirs).toContain("media.replycant.com/v1alpha1/Original");
    expect(dirs).toContain("media.replycant.com/v1alpha1/ThumbnailSet");
  });

  it("returns empty kind directories for empty registry", () => {
    const registry = new ManifestRegistry();
    expect(registry.registeredKindDirectories()).toEqual([]);
  });

  it("decodeYamlForExpectedKind returns decoded result when envelope matches", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    const yaml = `apiVersion: media.replycant.com/v1alpha1\nkind: Original\nid: photo-1\nname: test`;
    const result = registry.decodeYamlForExpectedKind(yaml, {
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
    });
    expect(result).not.toBeNull();
    expect(result!.apiVersion).toBe("media.replycant.com/v1alpha1");
    expect(result!.kind).toBe("Original");
    expect((result!.decoded as TestOriginal).id).toBe("photo-1");
  });

  it("decodeYamlForExpectedKind returns null when envelope fields are missing", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    const yaml = `id: photo-1\nname: test`;
    const result = registry.decodeYamlForExpectedKind(yaml, {
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
    });
    expect(result).toBeNull();
  });

  it("decodeYamlForExpectedKind throws when envelope does not match expected kind", () => {
    const registry = new ManifestRegistry();
    registry.register(testOriginalRegistration);
    const yaml = `apiVersion: media.replycant.com/v1alpha1\nkind: ThumbnailSet\nid: photo-1\nname: test`;
    expect(() =>
      registry.decodeYamlForExpectedKind(yaml, {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
      }),
    ).toThrow("Manifest envelope mismatch");
  });

  it("decodeYamlForExpectedKind throws when expected kind has no registration", () => {
    const registry = new ManifestRegistry();
    const yaml = `apiVersion: media.replycant.com/v1alpha1\nkind: Original\nid: photo-1\nname: test`;
    expect(() =>
      registry.decodeYamlForExpectedKind(yaml, {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
      }),
    ).toThrow("No registration for expected kind");
  });

  it("decodeYamlForExpectedKind returns null when decode returns null", () => {
    const registry = new ManifestRegistry();
    registry.register({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      decode: () => null,
      primaryKey: () => "",
    });
    const yaml = `apiVersion: media.replycant.com/v1alpha1\nkind: Original\nid: photo-1\nname: test`;
    const result = registry.decodeYamlForExpectedKind(yaml, {
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
    });
    expect(result).toBeNull();
  });
});
