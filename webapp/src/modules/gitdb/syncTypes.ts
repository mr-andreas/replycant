import type { RegisteredManifestRecord } from "./manifestRegistry";

// Carries both sides of one in-place record change so app-layer consumers can compute deltas
// against the prior synced state instead of only seeing the replacement value.
export interface ManifestRecordUpdate {
  previous: RegisteredManifestRecord;
  current: RegisteredManifestRecord;
}

// Carries one commit transition's worth of created/updated/deleted manifest records so the app
// can maintain its own view state without gitdb knowing the domain types.
export interface ManifestMutation {
  added: RegisteredManifestRecord[];
  updated: ManifestRecordUpdate[];
  removed: RegisteredManifestRecord[];
}

// Distinguishes incremental database updates from full cache replacement events so the app
// knows whether to patch or rebuild its state.
export type ManifestDatabaseChange =
  | { type: "incremental"; mutation: ManifestMutation }
  | { type: "fullReplace" };

// Defines the callback contract for broadcasting manifest database changes to app-layer consumers.
export type ManifestChangeListener = (change: ManifestDatabaseChange) => void;

// Defines gitdb-owned operational sync state. Domain-specific view state (originals, thumbnails)
// is no longer owned here; the app rebuilds it from ManifestDatabaseChange events.
export interface SyncSnapshot {
  syncing: boolean;
  error: string | null;
  syncedCommitHash: string | null;
  lastSyncAt: string | null;
  periodicSyncPaused: boolean;
  periodicSyncUserEnabled: boolean;
  syncIntervalMs: number;
  isOffHead: boolean;
  requiresHardResetPermission: boolean;
  cloneProgress: { phase: string; progress: number; loaded?: number; total?: number } | null;
}

// Exposes lightweight commit metadata for rewind/forward UI without exposing raw git objects.
export interface SyncCommitSummary {
  hash: string;
  message: string;
  authoredAt: string;
}

// Models onboarding probe outcomes so callers can distinguish retryable and fatal setup states.
export type OnboardingAuthorizationProbe =
  | { status: "authorized"; remoteHead: string }
  | { status: "pending_authorization" }
  | { status: "transient_error"; message: string }
  | { status: "fatal_error"; message: string };

// Defines the callback contract for broadcasting sync snapshots to non-graphical consumers.
export type SyncListener = (snapshot: SyncSnapshot) => void;

// Decouples mTLS identity handling so gitdb can request auth headers from host apps lazily.
export type MtlsHeadersProvider = () => Record<string, string> | null;

// Decouples age key access so encrypted manifests can be decrypted only when identity is unlocked.
export type AgePrivateKeyProvider = () => string | null;

// Captures all runtime/app-specific values the sync engine needs so it stays
// fully agnostic and never imports application configuration directly.
export interface SyncEngineConfig {
  gitBranch: string;
  syncIntervalMs: number;
  gitRemoteUrl: string;
  fsVolumeName: string;
  initialCloneDepth?: number;
  logPrefix?: string;
}
