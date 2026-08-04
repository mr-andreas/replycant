// Defines the minimum metadata contract needed to map YAML resources into deterministic table keys.
export interface GitdbEntityMetadata {
  name: string;
}

// Defines the minimum resource envelope needed for schema-safe persistence and querying.
export interface GitdbEntityRecord {
  apiVersion: string;
  kind: string;
  metadata: GitdbEntityMetadata;
}

// Describes one non-unique index so consumers can tune read performance per entity.
export interface EntityIndexDefinition<TRecord extends GitdbEntityRecord> {
  name: string;
  fieldPath: keyof TRecord | string;
  multiEntry?: boolean;
}

// Describes one registered entity schema so storage names and primary keys stay deterministic.
export interface EntitySchema<TRecord extends GitdbEntityRecord> {
  apiVersion: string;
  kind: string;
  indexes?: EntityIndexDefinition<TRecord>[];
}

// Identifies one entity family for register/query/upsert operations.
export interface EntityIdentity {
  apiVersion: string;
  kind: string;
}

// Defines one headless query request so consumers can read by primary key or index.
export interface EntityQuery<TRecord extends GitdbEntityRecord> {
  key?: string;
  where?: Partial<TRecord>;
  indexName?: string;
  equals?: IDBValidKey;
  limit?: number;
}

// Defines callback hooks that keep gitdb headless while still exposing progress and lifecycle signals.
export interface GitdbCallbacks {
  onState?: (state: {
    syncing: boolean;
    syncedCommitHash: string | null;
    periodicSyncPaused: boolean;
    requiresHardResetPermission: boolean;
    error: string | null;
  }) => void;
  onProgress?: (event: { operation: string; phase: string; progress: number; loaded?: number; total?: number }) => void;
  onOperationStart?: (event: { operation: string; reason?: "startup" | "manual" | "poll" }) => void;
  onOperationComplete?: (event: { operation: string; syncedCommitHash: string | null }) => void;
  onError?: (event: { operation: string; message: string }) => void;
  onDebug?: (event: { name: string; fields: Record<string, unknown> }) => void;
}
