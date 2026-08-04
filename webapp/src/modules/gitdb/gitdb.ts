import { SyncEngine } from "./syncEngine";
import { GitdbCallbacks } from "./contracts";
import { GitRepoPort } from "./gitRepoPort";
import { ManifestRegistry, type ManifestKindRegistration, type RegisteredManifestRecord } from "./manifestRegistry";
import { ManifestDatabase, type DerivedStoreQueryRequest, type ManifestQueryIdentity, type ManifestQueryRequest } from "./manifestDatabase";
import type { ManifestChangeListener, SyncCommitSummary, SyncEngineConfig, SyncListener, SyncSnapshot } from "./syncTypes";
import type { LfsPointerFields } from "./encryption";
import { runtimeConfig } from "../../lib/config";
import { timelineMonthCountsStore } from "./timelineDerivedStores";

// Defines constructor dependencies so gitdb stays headless and testable outside React.
export interface CreateGitdbOptions {
  callbacks?: GitdbCallbacks;
  onSnapshot?: SyncListener;
  onManifestChange?: ManifestChangeListener;
  mtlsHeadersProvider?: () => Record<string, string> | null;
  agePrivateKeyProvider?: () => string | null;
  syncDatabaseName?: string;
  initialCloneDepth?: number;
  registrations?: ManifestKindRegistration<any>[];
}

// Defines the public headless gitdb client that wraps sync, registration, and the query API.
export interface GitdbClient {
  initialize(): Promise<void>;
  bootstrapFromCache(): Promise<{ hasCachedData: boolean }>;
  bootstrap(): Promise<void>;
  shutdown(): void;
  syncNow(reason: "startup" | "manual" | "poll"): Promise<void>;
  setUserPeriodicSyncPaused(paused: boolean): Promise<void>;
  setSyncIntervalMs(intervalMs: number): Promise<void>;
  onVisibilityRegained(): Promise<void>;
  hardResetToRemoteAfterPermission(): Promise<void>;
  rewindToCommitAndPausePolling(commitHash: string): Promise<void>;
  forwardToRemoteHeadAndResumePolling(): Promise<void>;
  listRecentLocalCommits(limit?: number): Promise<SyncCommitSummary[]>;
  readTrackedRemoteHeadCommitHashOrNull(): Promise<string | null>;
  probeOnboardingAuthorization(): ReturnType<GitRepoPort["probeOnboardingAuthorization"]>;
  registerManifestKind<T>(registration: ManifestKindRegistration<T>): void;
  query(identity: ManifestQueryIdentity, request: ManifestQueryRequest): Promise<RegisteredManifestRecord[] | number>;
  queryPointers(paths: string[]): Promise<Map<string, LfsPointerFields>>;
  queryDerived<T = unknown>(storeName: string, request: DerivedStoreQueryRequest): Promise<T[] | number>;
}

// Bridges snapshot transitions into callback events so non-graphical consumers can observe sync lifecycle.
const emitCallbackEventsFromSnapshot = (
  previous: SyncSnapshot | null,
  next: SyncSnapshot,
  callbacks: GitdbCallbacks | undefined,
): void => {
  if (!callbacks) return;
  callbacks.onState?.({
    syncing: next.syncing,
    syncedCommitHash: next.syncedCommitHash,
    periodicSyncPaused: next.periodicSyncPaused,
    requiresHardResetPermission: next.requiresHardResetPermission,
    error: next.error,
  });
  if (next.cloneProgress) {
    const progressEvent: { operation: string; phase: string; progress: number; loaded?: number; total?: number } = {
      operation: "sync",
      phase: next.cloneProgress.phase,
      progress: next.cloneProgress.progress,
    };
    if (next.cloneProgress.loaded != null) progressEvent.loaded = next.cloneProgress.loaded;
    if (next.cloneProgress.total != null) progressEvent.total = next.cloneProgress.total;
    callbacks.onProgress?.(progressEvent);
  }
  if (!previous?.syncing && next.syncing) {
    callbacks.onOperationStart?.({ operation: "sync" });
  }
  if (previous?.syncing && !next.syncing) {
    callbacks.onOperationComplete?.({ operation: "sync", syncedCommitHash: next.syncedCommitHash });
  }
  if (next.error && next.error !== previous?.error) {
    callbacks.onError?.({ operation: "sync", message: next.error });
  }
};

// Resolves the git API URL from the current runtime so SyncEngine can run outside window-bound contexts.
const resolveGitRemoteUrl = (): string => {
  const runtimeOrigin =
    typeof globalThis.location?.origin === "string" ? globalThis.location.origin : "http://localhost";
  return new URL(`${runtimeConfig.apiBasePath}/git`, runtimeOrigin).toString();
};

// Creates a headless gitdb facade so app code can depend on one non-UI module boundary.
export const createGitdb = (options: CreateGitdbOptions = {}): GitdbClient => {
  let syncEngine: SyncEngine | null = null;
  let repoPort: GitRepoPort | null = null;
  const registry = new ManifestRegistry();
  let manifestDb: ManifestDatabase | null = null;
  let latestSnapshot: SyncSnapshot | null = null;

  for (const reg of options.registrations ?? []) {
    registry.register(reg);
  }

  const initialize = async (): Promise<void> => {
    if (syncEngine) return;
    manifestDb = new ManifestDatabase(
      registry.allRegistrations(),
      [timelineMonthCountsStore],
      options.syncDatabaseName ?? "gitdb-manifests-v1",
    );
    const listener: SyncListener = (snapshot) => {
      emitCallbackEventsFromSnapshot(latestSnapshot, snapshot, options.callbacks);
      latestSnapshot = snapshot;
      options.onSnapshot?.(snapshot);
    };
    const config: SyncEngineConfig = {
      gitBranch: runtimeConfig.gitBranch,
      syncIntervalMs: runtimeConfig.syncIntervalMs,
      gitRemoteUrl: resolveGitRemoteUrl(),
      fsVolumeName: "replycant-git-v3",
      initialCloneDepth: options.initialCloneDepth,
    };
    syncEngine = new SyncEngine(
      config,
      registry,
      manifestDb,
      listener,
      options.mtlsHeadersProvider ?? (() => null),
      options.agePrivateKeyProvider ?? (() => null),
    );
    if (options.onManifestChange) {
      syncEngine.onManifestChange(options.onManifestChange);
    }
    repoPort = syncEngine;
  };

  return {
    initialize,
    async bootstrapFromCache() {
      await initialize();
      return syncEngine!.bootstrapFromCache();
    },
    async bootstrap() {
      await initialize();
      await syncEngine!.bootstrap();
    },
    shutdown() {
      syncEngine?.stop();
      syncEngine = null;
      repoPort = null;
      manifestDb?.close();
      manifestDb = null;
    },
    async syncNow(reason) {
      await initialize();
      await syncEngine!.syncNow(reason);
    },
    async setUserPeriodicSyncPaused(paused) {
      await initialize();
      syncEngine!.setUserPeriodicSyncPaused(paused);
    },
    async setSyncIntervalMs(intervalMs) {
      await initialize();
      syncEngine!.setSyncIntervalMs(intervalMs);
    },
    async onVisibilityRegained() {
      await initialize();
      await syncEngine!.onVisibilityRegained();
    },
    async hardResetToRemoteAfterPermission() {
      await initialize();
      await repoPort!.hardResetToRemoteAfterPermission();
    },
    async rewindToCommitAndPausePolling(commitHash) {
      await initialize();
      await repoPort!.rewindToCommitAndPausePolling(commitHash);
    },
    async forwardToRemoteHeadAndResumePolling() {
      await initialize();
      await repoPort!.forwardToRemoteHeadAndResumePolling();
    },
    async listRecentLocalCommits(limit) {
      await initialize();
      return repoPort!.listRecentLocalCommits(limit);
    },
    async readTrackedRemoteHeadCommitHashOrNull() {
      await initialize();
      return repoPort!.readTrackedRemoteHeadCommitHashOrNull();
    },
    async probeOnboardingAuthorization() {
      await initialize();
      return repoPort!.probeOnboardingAuthorization();
    },
    registerManifestKind(registration) {
      registry.register(registration);
    },
    async query(identity, request) {
      await initialize();
      return manifestDb!.query(identity, request);
    },
    async queryPointers(paths) {
      await initialize();
      return manifestDb!.queryPointers(paths);
    },
    async queryDerived(storeName, request) {
      await initialize();
      return manifestDb!.queryDerived(storeName, request);
    },
  };
};
