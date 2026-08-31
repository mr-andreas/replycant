import { describe, expect, it, vi } from "vitest";
import { DatabaseVersionError } from "./databaseVersion";
import { ManifestRegistry } from "./manifestRegistry";
import { ManifestBlobReader } from "./manifestBlobReader";
import { encryptManifestYaml, importTestKek } from "./testEncryption";

// Builds a minimal registry so blob-reader decode tests validate key resolution behavior.
const createRegistry = (): ManifestRegistry => {
  const registry = new ManifestRegistry();
  registry.register({
    apiVersion: "media.replycant.com/v1alpha1",
    kind: "Original",
    decode: (rawYaml: string) => {
      if (!rawYaml.includes("kind: Original")) return null;
      const name = rawYaml.match(/name:\s*(\S+)/)?.[1] ?? "unknown";
      const deviceSpace = rawYaml.match(/deviceSpace:\s*(\S+)/)?.[1] ?? "dev";
      return {
        kind: "Original",
        metadata: { name, deviceSpace },
        spec: { id: name },
      };
    },
    primaryKey: (decoded: any) => `${decoded.metadata.deviceSpace}/${decoded.metadata.name}`,
  });
  return registry;
};

// Builds a reader with no real age identity so decrypt tests inject KEKs via spies.
const createReader = (): ManifestBlobReader =>
  new ManifestBlobReader({
    fs: { promises: {} } as never,
    gitdir: "/repo",
    registry: createRegistry(),
    agePrivateKeyProvider: () => null,
    cache: {},
  });

describe("ManifestBlobReader", () => {
  it("accepts a commit whose gitdb/version matches this client", async () => {
    const reader = createReader();
    vi.spyOn(reader, "readBlobAtCommitPathOrNull").mockResolvedValue({
      blob: new TextEncoder().encode("1\n"),
      oid: "version-oid",
    });
    await expect(reader.assertSupportedDatabaseVersion("commit")).resolves.toBeUndefined();
  });

  it("rejects a missing or unsupported gitdb/version marker", async () => {
    const reader = createReader();
    const missing = vi.spyOn(reader, "readBlobAtCommitPathOrNull").mockResolvedValue(null);
    await expect(reader.assertSupportedDatabaseVersion("commit")).rejects.toBeInstanceOf(DatabaseVersionError);
    missing.mockResolvedValue({ blob: new TextEncoder().encode("2\n"), oid: "version-oid" });
    await expect(reader.assertSupportedDatabaseVersion("commit")).rejects.toThrow(/unsupported gitdb database version 2/);
  });

  it("infers expected kind from canonical manifest path", () => {
    const reader = createReader();
    expect(
      reader.inferExpectedKindFromPath("manifests/dev/media.replycant.com/v1alpha1/Original/photo-1.yaml"),
    ).toEqual({ apiVersion: "media.replycant.com/v1alpha1", kind: "Original" });
  });

  it("decodes yaml to a registered manifest record", () => {
    const reader = createReader();
    const record = reader.decodeYamlToRecord(
      [
        "apiVersion: media.replycant.com/v1alpha1",
        "kind: Original",
        "name: photo-1",
        "deviceSpace: devA",
      ].join("\n"),
      { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
    );
    expect(record?.key).toBe("devA/photo-1");
    expect(record?.kind).toBe("Original");
  });

  // Ensures a hostile server cannot strip the envelope and have clients accept plaintext YAML.
  it("rejects plaintext manifest blobs", async () => {
    const reader = createReader();
    await expect(
      reader.decodeManifestBlobToYaml(
        "commit",
        new TextEncoder().encode("apiVersion: media.replycant.com/v1alpha1\nkind: Original\n"),
      ),
    ).rejects.toThrow(/plaintext manifest rejected/);
  });

  // Verifies encrypted envelopes still decrypt after plaintext passthrough was removed.
  it("decrypts encrypted manifest envelopes", async () => {
    const reader = createReader();
    const yaml = "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\n";
    const blob = await encryptManifestYaml(yaml);
    vi.spyOn(reader, "loadKekEpoch").mockResolvedValue(await importTestKek());
    await expect(reader.decodeManifestBlobToYaml("commit", blob)).resolves.toBe(yaml);
  });
});
