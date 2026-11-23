import { afterEach, describe, expect, it, vi } from "vitest";
import git from "isomorphic-git";
import { ManifestRegistry } from "./manifestRegistry";
import { EncryptionIntegrityError, ManifestBlobReader } from "./manifestBlobReader";
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
    localStorage.clear();
  });

  // Serves commit/tree/blob the way production reads gitdb/version:
  // filepath first, then root paths only to prove absence.
  const mockVersionRead = (opts: {
    rootEntries?: Array<{ path: string; oid?: string; type?: "blob" | "tree"; mode?: string }>;
    versionText?: string;
    failAt?: "commit" | "blob";
    blobError?: Error;
  } = {}) => {
    vi.spyOn(git, "readCommit").mockImplementation(async () => {
      if (opts.failAt === "commit") throw new Error("commit missing");
      return { oid: "commit", commit: { tree: "root-oid" }, payload: "" } as never;
    });
    vi.spyOn(git, "readTree").mockImplementation(async ({ oid }: { oid: string }) => {
      if (oid !== "root-oid") throw new Error(`unknown tree ${oid}`);
      return {
        oid: "root-oid",
        tree: opts.rootEntries ?? [
          { path: "gitdb", oid: "gitdb-oid", type: "tree", mode: "040000" },
        ],
      } as never;
    });
    vi.spyOn(git, "readBlob").mockImplementation(async () => {
      if (opts.failAt === "blob") {
        throw opts.blobError ?? Object.assign(new Error("Could not find gitdb/version"), { code: "NotFoundError", name: "NotFoundError" });
      }
      return {
        blob: new TextEncoder().encode(opts.versionText ?? "3\n"),
        oid: "version-oid",
      };
    });
  };

  it("accepts a commit whose gitdb/version matches this client", async () => {
    const reader = createReader();
    mockVersionRead();
    await expect(reader.assertSupportedDatabaseVersion("commit")).resolves.toBeUndefined();
  });

  it("reads gitdb/version by filepath even when the gitdb entry has no type", async () => {
    const reader = createReader();
    mockVersionRead({
      rootEntries: [{ path: "gitdb", oid: "gitdb-oid" }],
    });
    await expect(reader.readDatabaseVersion("commit")).resolves.toBe(3);
  });

  it("rejects a missing gitdb/version marker when the tree is readable", async () => {
    const reader = createReader();
    mockVersionRead({
      rootEntries: [{ path: "manifests", oid: "manifests-oid", type: "tree", mode: "040000" }],
      failAt: "blob",
    });
    await expect(reader.readDatabaseVersion("commit")).rejects.toThrow(/gitdb\/version is missing/);
    await expect(reader.assertSupportedDatabaseVersion("commit")).rejects.toThrow(/gitdb\/version is missing/);
  });

  it("throws DatabaseVersionUnreadableError when the commit cannot be read", async () => {
    const reader = createReader();
    mockVersionRead({ failAt: "commit" });
    await expect(reader.readDatabaseVersion("commit")).rejects.toBeInstanceOf(
      DatabaseVersionUnreadableError,
    );
    await expect(reader.readDatabaseVersionOrNull("commit")).resolves.toBeNull();
  });

  it("throws DatabaseVersionUnreadableError when gitdb exists but the version blob cannot be read", async () => {
    const reader = createReader();
    mockVersionRead({
      rootEntries: [{ path: "gitdb", oid: "gitdb-oid" }],
      failAt: "blob",
      blobError: new Error("pack index missing"),
    });
    await expect(reader.readDatabaseVersion("commit")).rejects.toBeInstanceOf(
      DatabaseVersionUnreadableError,
    );
  });

  it("rejects an unsupported gitdb/version marker", async () => {
    const reader = createReader();
    mockVersionRead({ versionText: "4\n" });
    await expect(reader.assertSupportedDatabaseVersion("commit")).rejects.toThrow(/unsupported gitdb database version 4/);
  });

  it("infers expected kind from canonical manifest path", () => {
    const reader = createReader();
    expect(
      reader.inferExpectedKindFromPath(
        "encryptionspaces/dev/manifests/media.replycant.com/v1alpha1/Original/photo-1.yaml",
      ),
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
    ).rejects.toThrow(/the manifest is plaintext/);
  });

  // Verifies encrypted envelopes still decrypt after plaintext passthrough was removed.
  it("decrypts encrypted manifest envelopes", async () => {
    const reader = createReader();
    const yaml = "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\n";
    const blob = await encryptManifestYaml(yaml);
    vi.spyOn(reader, "loadKekEpoch").mockResolvedValue(await importTestKek());
    await expect(reader.decodeManifestBlobToYaml("commit", blob)).resolves.toBe(yaml);
  });

  // The path is the only place a space name is trusted. A stale
  // deviceSpace field in the YAML must not change the record key.
  it("takes the space from the path", () => {
    const reader = createReader();
    const record = reader.decodeYamlToRecord(
      [
        "apiVersion: media.replycant.com/v1alpha1",
        "kind: Original",
        "name: photo-1",
        "deviceSpace: hostile",
      ].join("\n"),
      { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
      "encryptionspaces/album/manifests/media.replycant.com/v1alpha1/Original/photo-1.yaml",
    );
    expect(record?.key).toBe("album/photo-1");
  });

  // A space with its own current file never falls back to the library key.
  it("does not open a space object with the library key", async () => {
    const reader = createReader();
    vi.spyOn(git, "readBlob").mockImplementation(async ({ filepath }: { filepath?: string }) => {
      if (filepath === "encryptionspaces/album/encryption/current") {
        return { blob: new TextEncoder().encode("1\n"), oid: "space-current" } as never;
      }
      throw new Error(`missing ${filepath}`);
    });
    const loadKek = vi.spyOn(reader, "loadKekEpoch").mockRejectedValue(new Error("wrong key"));
    const blob = await encryptManifestYaml("kind: Original\n");
    await expect(
      reader.decodeManifestBlobToYaml(
        "commit",
        blob,
        "encryptionspaces/album/manifests/media.replycant.com/v1alpha1/Original/photo-1.yaml",
      ),
    ).rejects.toBeInstanceOf(EncryptionIntegrityError);
    expect(loadKek).toHaveBeenCalledWith("commit", 1, "encryptionspaces/album/encryption");
    expect(loadKek).not.toHaveBeenCalledWith("commit", 1, "encryption");
  });

  // The first observation of a space is trusted. Adding or removing
  // its own key set later is a substitution, not a migration.
  it("refuses a space that changes key set", async () => {
    const reader = createReader();
    let own = false;
    vi.spyOn(git, "readBlob").mockImplementation(async ({ filepath }: { filepath?: string }) => {
      if (own && filepath === "encryptionspaces/album/encryption/current") {
        return { blob: new TextEncoder().encode("1\n"), oid: "space-current" } as never;
      }
      throw new Error(`missing ${filepath}`);
    });
    const path = "encryptionspaces/album/manifests/media.replycant.com/v1alpha1/Original/photo-1.yaml";
    await expect(reader.keySetRoot("commit", path)).resolves.toBe("encryption");
    own = true;
    await expect(reader.keySetRoot("later", path)).rejects.toThrow(/changed key set/);
  });

  // A full resync decodes every manifest in a space. The space's key
  // set is the same for the whole commit, so the current file is read once.
  it("reads a space key set once while decoding several manifests", async () => {
    const reader = createReader();
    const readBlob = vi.spyOn(git, "readBlob").mockImplementation(async ({ filepath }: { filepath?: string }) => {
      if (filepath?.endsWith("encryption/current")) {
        throw Object.assign(new Error(`missing ${filepath}`), { code: "NotFoundError", name: "NotFoundError" });
      }
      throw new Error(`missing ${filepath}`);
    });
    vi.spyOn(reader, "loadKekEpoch").mockResolvedValue(await importTestKek());
    const blob = await encryptManifestYaml(
      "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\n",
    );
    const path = "encryptionspaces/album/manifests/media.replycant.com/v1alpha1/Original/photo-1.yaml";
    await reader.decodeManifestBlobToYaml("commit", blob, path);
    await reader.decodeManifestBlobToYaml("commit", blob, path);
    await reader.decodeManifestBlobToYaml("commit", blob, path);
    const currentReads = readBlob.mock.calls.filter((call) =>
      String(call[0]?.filepath ?? "").endsWith("encryption/current"),
    );
    expect(currentReads).toHaveLength(1);
  });

  // A missing epoch is the library refusing to open, not a prompt to try another key.
  it("stops when the listed epoch cannot be read", async () => {
    const reader = new ManifestBlobReader({
      fs: { promises: {} } as never,
      gitdir: "/repo-missing-epoch",
      registry: createRegistry(),
      agePrivateKeyProvider: () => "not-a-real-key",
      cache: {},
    });
    vi.spyOn(git, "readBlob").mockRejectedValue(new Error("missing epoch"));
    await expect(reader.loadKekEpoch("commit", 1, "encryption")).rejects.toBeInstanceOf(
      EncryptionIntegrityError,
    );
  });
});
