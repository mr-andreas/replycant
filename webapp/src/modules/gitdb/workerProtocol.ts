import type { ManifestDatabaseChange, OnboardingAuthorizationProbe, SyncCommitSummary, SyncEngineConfig, SyncSnapshot } from "./syncTypes";
import type { ManifestIndexDefinition, RegisteredManifestRecord } from "./manifestRegistry";
import type { DerivedStoreQueryRequest, ManifestQueryIdentity, ManifestQueryRequest } from "./manifestDatabase";
import type { LfsPointerFields } from "./encryption";

// Defines worker-callable SyncEngine operations so the main thread can use typed RPC messages.
export type SyncWorkerRpcMethod =
  | "bootstrapFromCache"
  | "bootstrap"
  | "syncNow"
  | "setUserPeriodicSyncPaused"
  | "setSyncIntervalMs"
  | "stop"
  | "onVisibilityRegained"
  | "hardResetToRemoteAfterPermission"
  | "rewindToCommitAndPausePolling"
  | "forwardToRemoteHeadAndResumePolling"
  | "listRecentLocalCommits"
  | "readTrackedRemoteHeadCommitHashOrNull"
  | "probeOnboardingAuthorization"
  | "query"
  | "queryPointers"
  | "queryDerived";

// Defines one method-specific argument tuple so RPC calls remain strongly typed on both ends.
export interface SyncWorkerRpcArgsMap {
  bootstrapFromCache: [];
  bootstrap: [];
  syncNow: ["startup" | "manual" | "poll"];
  setUserPeriodicSyncPaused: [boolean];
  setSyncIntervalMs: [number];
  stop: [];
  onVisibilityRegained: [];
  hardResetToRemoteAfterPermission: [];
  rewindToCommitAndPausePolling: [string];
  forwardToRemoteHeadAndResumePolling: [];
  listRecentLocalCommits: [number?];
  readTrackedRemoteHeadCommitHashOrNull: [];
  probeOnboardingAuthorization: [];
  query: [ManifestQueryIdentity, ManifestQueryRequest];
  queryPointers: [string[]];
  queryDerived: [string, DerivedStoreQueryRequest];
}

// Defines one method-specific return type so RPC responses preserve GitdbClient contracts.
export interface SyncWorkerRpcResultMap {
  bootstrapFromCache: { hasCachedData: boolean };
  bootstrap: void;
  syncNow: void;
  setUserPeriodicSyncPaused: void;
  setSyncIntervalMs: void;
  stop: void;
  onVisibilityRegained: void;
  hardResetToRemoteAfterPermission: void;
  rewindToCommitAndPausePolling: void;
  forwardToRemoteHeadAndResumePolling: void;
  listRecentLocalCommits: SyncCommitSummary[];
  readTrackedRemoteHeadCommitHashOrNull: string | null;
  probeOnboardingAuthorization: OnboardingAuthorizationProbe;
  query: RegisteredManifestRecord[] | number;
  queryPointers: [string, LfsPointerFields][];
  queryDerived: unknown[] | number;
}

// Carries worker initialization state required before SyncEngine can serve RPC calls.
export interface SyncWorkerInitMessage {
  type: "init";
  syncEngineConfig: SyncEngineConfig;
  syncDatabaseName?: string;
  registrations?: SerializableManifestRegistration[];
}

// Serializable registration payload that can cross the worker boundary (decode/primaryKey are
// re-registered on the worker side, not serialized).
export interface SerializableManifestRegistration {
  apiVersion: string;
  kind: string;
  indexes?: ManifestIndexDefinition[];
}

// Pushes auth provider snapshots so worker-side providers can resolve current credentials lazily.
export interface SyncWorkerProvidersMessage {
  type: "providers";
  mtlsHeaders: Record<string, string> | null;
  agePrivateKey: string | null;
}

// Pushes visibility state from the UI thread so worker polling behavior matches tab lifecycle.
export interface SyncWorkerVisibilityMessage {
  type: "visibility";
  hidden: boolean;
}

// Carries one typed RPC invocation from main thread to worker.
export interface SyncWorkerRpcMessage {
  type: "rpc";
  callId: number;
  method: SyncWorkerRpcMethod;
  args: unknown[];
}

// Groups all main-thread message variants handled by the worker.
export type SyncWorkerInboundMessage =
  | SyncWorkerInitMessage
  | SyncWorkerProvidersMessage
  | SyncWorkerVisibilityMessage
  | SyncWorkerRpcMessage;

// Publishes snapshot updates so UI state can react to sync transitions in real time.
export interface SyncWorkerSnapshotMessage {
  type: "snapshot";
  data: SyncSnapshot;
}

// Publishes manifest database changes so the app can rebuild its view state.
export interface SyncWorkerManifestChangeMessage {
  type: "manifestChange";
  data: ManifestDatabaseChange;
}

// Confirms worker initialization so the client can start issuing RPC calls.
export interface SyncWorkerReadyMessage {
  type: "ready";
}

// Returns one typed RPC outcome to settle the corresponding call promise.
export interface SyncWorkerRpcResultMessage {
  type: "rpc-result";
  callId: number;
  method: SyncWorkerRpcMethod;
  result?: unknown;
  error?: string;
}

// Groups all outbound worker message variants consumed by the client.
export type SyncWorkerOutboundMessage =
  | SyncWorkerSnapshotMessage
  | SyncWorkerManifestChangeMessage
  | SyncWorkerReadyMessage
  | SyncWorkerRpcResultMessage;
