import { openDB, IDBPDatabase } from "idb";
import { EntityIdentity, EntityQuery, EntitySchema, GitdbEntityRecord } from "./contracts";

// Normalizes resource identity into one deterministic object-store name derived from apiVersion and kind.
export const deriveEntityStoreName = (identity: EntityIdentity): string => {
  const normalizedApiVersion = identity.apiVersion.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "").toLowerCase();
  const normalizedKind = identity.kind.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  return `${normalizedApiVersion}_${normalizedKind}`;
};

// Produces one stable schema key so registration lookups do not depend on object identity.
const schemaKey = (identity: EntityIdentity): string => `${identity.apiVersion}::${identity.kind}`;

// Validates metadata.name against YAML filename so primary-key semantics stay aligned with git storage.
const assertMetadataNameMatchesYamlFilename = (metadataName: string, yamlFilenameWithoutSuffix: string): void => {
  if (metadataName === yamlFilenameWithoutSuffix) return;
  throw new Error(
    `Entity metadata.name must match YAML filename. metadata.name=${metadataName}, filename=${yamlFilenameWithoutSuffix}`,
  );
};

// Extracts YAML filename stem so metadata.name can be validated before persistence.
const extractYamlStem = (yamlPath: string): string => {
  const parts = yamlPath.split("/");
  const filename = parts.at(-1) ?? yamlPath;
  if (!filename.endsWith(".yaml")) {
    throw new Error(`Entity source path must end with .yaml. received=${yamlPath}`);
  }
  const shard1 = parts.at(-3) ?? "";
  const shard2 = parts.at(-2) ?? "";
  return `${shard1}${shard2}${filename.slice(0, -5)}`;
};

// Owns schema registration and typed entity reads/writes for the headless gitdb entity database.
export class GitdbEntityRegistry {
  private readonly schemas = new Map<string, EntitySchema<GitdbEntityRecord>>();
  private db: IDBPDatabase | null = null;

  // Captures a schema contract before initialization so object stores and indexes can be created deterministically.
  registerEntity<TRecord extends GitdbEntityRecord>(schema: EntitySchema<TRecord>): void {
    if (this.db) {
      throw new Error("registerEntity must be called before initialize.");
    }
    const key = schemaKey(schema);
    this.schemas.set(key, schema as EntitySchema<GitdbEntityRecord>);
  }

  // Opens the entity database and creates one store per registered schema with non-unique indexes.
  async initialize(databaseName: string = "gitdb-entities"): Promise<void> {
    if (this.db) return;
    const schemas = [...this.schemas.values()];
    this.db = await openDB(databaseName, 1, {
      upgrade(database) {
        for (const schema of schemas) {
          const storeName = deriveEntityStoreName(schema);
          if (database.objectStoreNames.contains(storeName)) continue;
          const store = database.createObjectStore(storeName, { keyPath: "metadata.name" });
          for (const index of schema.indexes ?? []) {
            store.createIndex(index.name, index.fieldPath as string, {
              unique: false,
              multiEntry: Boolean(index.multiEntry),
            });
          }
        }
      },
    });
  }

  // Releases database handles so tests and app resets can reopen cleanly without blocked upgrades.
  close(): void {
    this.db?.close();
    this.db = null;
  }

  // Persists one validated entity row using metadata.name as the canonical primary key.
  async upsertEntity<TRecord extends GitdbEntityRecord>(
    identity: EntityIdentity,
    row: TRecord,
    sourceYamlPath: string,
  ): Promise<void> {
    if (!this.db) {
      throw new Error("initialize must be called before upsertEntity.");
    }
    const expectedName = extractYamlStem(sourceYamlPath);
    assertMetadataNameMatchesYamlFilename(row.metadata.name, expectedName);
    const storeName = deriveEntityStoreName(identity);
    await this.db.put(storeName, row as unknown as Record<string, unknown>);
  }

  // Runs a typed read query against one registered entity store.
  async queryEntity<TRecord extends GitdbEntityRecord>(
    identity: EntityIdentity,
    query: EntityQuery<TRecord>,
  ): Promise<TRecord[]> {
    if (!this.db) {
      throw new Error("initialize must be called before queryEntity.");
    }
    const storeName = deriveEntityStoreName(identity);
    const transaction = this.db.transaction(storeName, "readonly");
    const store = transaction.objectStore(storeName);

    if (query.key) {
      const row = (await store.get(query.key)) as TRecord | undefined;
      return row ? [row] : [];
    }

    if (query.indexName && query.equals !== undefined) {
      const rows = (await store.index(query.indexName).getAll(query.equals, query.limit)) as TRecord[];
      return rows;
    }

    const rows = (await store.getAll(undefined, query.limit)) as TRecord[];
    if (!query.where) return rows;
    return rows.filter((row) =>
      Object.entries(query.where ?? {}).every(([field, expected]) => Object.is((row as Record<string, unknown>)[field], expected)),
    );
  }
}
