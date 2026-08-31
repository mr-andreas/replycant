import { afterEach, describe, expect, it, vi } from "vitest";
import git from "isomorphic-git";
import { ManifestRegistry } from "./manifestRegistry";
import { ManifestBlobReader } from "./manifestBlobReader";
import { DatabaseVersionUnreadableError } from "./databaseVersion";
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
  afterEach(() => {
    vi.restoreAllMocks();
  });

  // Walks a commit the way production does so tests can prove absence
  // versus a failed object read instead of swallowing every error as 0.
  const mockVersionWalk = (opts: {
    rootEntries?: Array<{ path: string; oid: string; type: "blob" | "tree"; mode: string }>;
    gitdbEntries?: Array<{ path: string; oid: string; type: "blob" | "tree"; mode: string }>;
    versionText?: string;
    failAt?: "commit" | "rootTree" | "gitdbTree" | "blob";
  } = {}) => {
    vi.spyOn(git, "readCommit").mockImplementation(async () => {
      if (opts.failAt === "commit") throw new Error("commit missing");
      return { oid: "commit", commit: { tree: "root-oid" }, payload: "" } as never;
    });
    vi.spyOn(git, "readTree").mockImplementation(async ({ oid }: { oid: string }) => {
      if (oid === "root-oid") {
        if (opts.failAt === "rootTree") throw new Error("root tree missing");
        return {
          oid: "root-oid",
          tree: opts.rootEntries ?? [
            { path: "gitdb", oid: "gitdb-oid", type: "tree", mode: "040000" },
          ],
        };
      }
      if (oid === "gitdb-oid") {
        if (opts.failAt === "gitdbTree") throw new Error("gitdb tree missing");
        return {
          oid: "gitdb-oid",
          tree: opts.gitdbEntries ?? [
            { path: "version", oid: "version-oid", type: "blob", mode: "100644" },
          ],
        };
      }
      throw new Error(`unknown tree ${oid}`);
    });
    vi.spyOn(git, "readBlob").mockImplementation(async () => {
      if (opts.failAt === "blob") throw new Error("blob missing");
      return {
        blob: new TextEncoder().encode(opts.versionText ?? "1\n"),
        oid: "version-oid",
      };
    });
  };

  it("accepts a commit whose gitdb/version matches this client", async () => {
    const reader = createReader();
    mockVersionWalk();
    await expect(reader.assertSupportedDatabaseVersion("commit")).resolves.toBeUndefined();
  });

  it("treats a missing gitdb/version marker as version 0 when the tree is readable", async () => {
    const reader = createReader();
    mockVersionWalk({ rootEntries: [] });
    await expect(reader.readDatabaseVersion("commit")).resolves.toBe(0);
    await expect(reader.assertSupportedDatabaseVersion("commit")).resolves.toBeUndefined();
  });

  it("throws DatabaseVersionUnreadableError when the tree cannot be read", async () => {
    const reader = createReader();
    mockVersionWalk({ failAt: "rootTree" });
    await expect(reader.readDatabaseVersion("commit")).rejects.toBeInstanceOf(
      DatabaseVersionUnreadableError,
    );
    await expect(reader.readDatabaseVersionOrNull("commit")).resolves.toBeNull();
  });

  it("rejects an unsupported gitdb/version marker", async () => {
    const reader = createReader();
    mockVersionWalk({ versionText: "2\n" });
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
