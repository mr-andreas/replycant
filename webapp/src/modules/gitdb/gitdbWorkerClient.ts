import { runtimeConfig } from "../../lib/config";
import { CreateGitdbOptions, GitdbClient } from "./gitdb";
import type { ManifestKindRegistration, RegisteredManifestRecord } from "./manifestRegistry";
import type { DerivedStoreQueryRequest, ManifestQueryIdentity, ManifestQueryRequest } from "./manifestDatabase";
import type { ManifestDatabaseChange, SyncEngineConfig, SyncSnapshot } from "./syncTypes";
import type { LfsPointerFields } from "./encryption";
import {
  SyncWorkerInboundMessage,
  SyncWorkerOutboundMessage,
  SyncWorkerRpcArgsMap,
  SyncWorkerRpcMethod,
  SyncWorkerRpcResultMap,
} from "./workerProtocol";

type PendingCall = {
  resolve: (value: any) => void;
  reject: (reason?: unknown) => void;
};

const WORKER_READY_TIMEOUT_MS = 8_000;
const WORKER_READY_MAX_RETRIES = 1;

// Adds worker-specific controls so runtime hooks can push provider and visibility state.
export interface GitdbWorkerClient extends GitdbClient {
  updateProviders(mtlsHeaders: Record<string, string> | null, agePrivateKey: string | null): void;
  updateVisibility(hidden: boolean): void;
}

// Resolves git API URL from runtime origin so worker sync can target the same backend as the UI.
const resolveGitRemoteUrl = (): string => {
  const runtimeOrigin =
    typeof globalThis.location?.origin === "string" ? globalThis.location.origin : "http://localhost";
  return new URL(`${runtimeConfig.apiBasePath}/git`, runtimeOrigin).toString();
};

// Bridges snapshot transitions into callback events so worker and in-process clients share semantics.
const emitCallbackEventsFromSnapshot = (
  previous: SyncSnapshot | null,
  next: SyncSnapshot,
  callbacks: CreateGitdbOptions["callbacks"],
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

// Creates a worker-backed gitdb client so heavy sync/crypto/git work runs off the main thread.
export const createGitdbWorker = (options: CreateGitdbOptions = {}): GitdbWorkerClient => {
  let worker: Worker | null = null;
  let latestSnapshot: SyncSnapshot | null = null;
  let nextCallId = 1;
  const pendingCalls = new Map<number, PendingCall>();
  let readyPromise: Promise<void> | null = null;
  let readyResolve: (() => void) | null = null;
  let readyReject: ((reason?: unknown) => void) | null = null;
  let setupPromise: Promise<void> | null = null;
  let workerReady = false;

  const rejectPendingCalls = (reason: unknown): void => {
    for (const pending of pendingCalls.values()) {
      pending.reject(reason);
    }
    pendingCalls.clear();
  };

  const postToWorker = (message: SyncWorkerInboundMessage): void => {
    if (!worker) {
      throw new Error("Sync worker is not initialized.");
    }
    worker.postMessage(message);
  };

  const handleWorkerMessage = (event: MessageEvent<SyncWorkerOutboundMessage>): void => {
    const message = event.data;
    if (message.type === "ready") {
      workerReady = true;
      readyResolve?.();
      readyResolve = null;
      readyReject = null;
      return;
    }

    if (message.type === "snapshot") {
      emitCallbackEventsFromSnapshot(latestSnapshot, message.data, options.callbacks);
      latestSnapshot = message.data;
      options.onSnapshot?.(message.data);
      return;
    }

    if (message.type === "manifestChange") {
      options.onManifestChange?.(message.data as ManifestDatabaseChange);
      return;
    }

    const pending = pendingCalls.get(message.callId);
    if (!pending) return;
    pendingCalls.delete(message.callId);
    if (message.error) {
      pending.reject(new Error(message.error));
      return;
    }
    pending.resolve(message.result);
  };

  const startWorker = async (retryCount: number): Promise<void> => {
    worker = new Worker(new URL("./syncWorker.ts", import.meta.url), { type: "module" });
    workerReady = false;
    worker.addEventListener("message", handleWorkerMessage);
    worker.addEventListener("error", (event) => {
      const message = event.message || "Sync worker crashed.";
      workerReady = false;
      readyReject?.(new Error(message));
      readyResolve = null;
      readyReject = null;
      rejectPendingCalls(new Error(message));
    });

    readyPromise = new Promise<void>((resolve, reject) => {
      readyResolve = resolve;
      readyReject = reject;
    });

    const syncEngineConfig: SyncEngineConfig = {
      gitBranch: runtimeConfig.gitBranch,
      syncIntervalMs: runtimeConfig.syncIntervalMs,
      gitRemoteUrl: resolveGitRemoteUrl(),
      fsVolumeName: "replycant-git-v3",
      initialCloneDepth: options.initialCloneDepth,
    };
    postToWorker({
      type: "init",
      syncEngineConfig,
      syncDatabaseName: options.syncDatabaseName,
      registrations: (options.registrations ?? []).map((r) => ({
        apiVersion: r.apiVersion,
        kind: r.kind,
        indexes: r.indexes,
      })),
    });
    postToWorker({
      type: "providers",
      mtlsHeaders: options.mtlsHeadersProvider?.() ?? null,
      agePrivateKey: options.agePrivateKeyProvider?.() ?? null,
    });
    let readyTimeoutId: ReturnType<typeof setTimeout> | null = null;
    const readyTimeoutPromise = new Promise<never>((_resolve, reject) => {
      readyTimeoutId = setTimeout(() => {
        reject(new Error("Sync worker ready timeout."));
      }, WORKER_READY_TIMEOUT_MS);
    });
    try {
      await Promise.race([readyPromise, readyTimeoutPromise]);
    } catch (error) {
      worker?.terminate();
      worker = null;
      workerReady = false;
      readyPromise = null;
      readyResolve = null;
      readyReject = null;
      if (
        error instanceof Error
        && error.message === "Sync worker ready timeout."
        && retryCount < WORKER_READY_MAX_RETRIES
      ) {
        return startWorker(retryCount + 1);
      }
      throw error;
    } finally {
      if (readyTimeoutId !== null) {
        clearTimeout(readyTimeoutId);
      }
    }
  };

  // Waits for worker readiness with bounded retries so startup recovers from transient module-load stalls.
  const setupWorker = (): Promise<void> => {
    if (workerReady && worker) return Promise.resolve();
    if (setupPromise) return setupPromise;
    setupPromise = startWorker(0).finally(() => {
      setupPromise = null;
    });
    return setupPromise;
  };

  const callRpc = async <M extends SyncWorkerRpcMethod>(
    method: M,
    ...args: SyncWorkerRpcArgsMap[M]
  ): Promise<SyncWorkerRpcResultMap[M]> => {
    await setupWorker();
    return new Promise<SyncWorkerRpcResultMap[M]>((resolve, reject) => {
      const callId = nextCallId++;
      pendingCalls.set(callId, { resolve, reject });
      postToWorker({
        type: "rpc",
        callId,
        method,
        args,
      });
    });
  };

  return {
    initialize: setupWorker,
    bootstrapFromCache: () => callRpc("bootstrapFromCache"),
    bootstrap: () => callRpc("bootstrap"),
    shutdown() {
      if (!worker) return;
      worker.terminate();
      worker = null;
      workerReady = false;
      setupPromise = null;
      readyPromise = null;
      readyResolve = null;
      readyReject = null;
      rejectPendingCalls(new Error("Sync worker terminated."));
    },
    syncNow: (reason) => callRpc("syncNow", reason),
    setUserPeriodicSyncPaused: (paused) => callRpc("setUserPeriodicSyncPaused", paused),
    setSyncIntervalMs: (intervalMs) => callRpc("setSyncIntervalMs", intervalMs),
    onVisibilityRegained: () => callRpc("onVisibilityRegained"),
    hardResetToRemoteAfterPermission: () => callRpc("hardResetToRemoteAfterPermission"),
    rewindToCommitAndPausePolling: (commitHash) => callRpc("rewindToCommitAndPausePolling", commitHash),
    forwardToRemoteHeadAndResumePolling: () => callRpc("forwardToRemoteHeadAndResumePolling"),
    listRecentLocalCommits: (limit) => callRpc("listRecentLocalCommits", limit),
    readTrackedRemoteHeadCommitHashOrNull: () => callRpc("readTrackedRemoteHeadCommitHashOrNull"),
    probeOnboardingAuthorization: () => callRpc("probeOnboardingAuthorization"),
    registerManifestKind<T>(_registration: ManifestKindRegistration<T>) {
      // Registration must happen independently on each side of the worker boundary.
      // The worker-side registry is populated via the init message; the main-thread side
      // does not need to register again since queries are forwarded to the worker.
    },
    async query(identity: ManifestQueryIdentity, request: ManifestQueryRequest): Promise<RegisteredManifestRecord[] | number> {
      return callRpc("query", identity, request);
    },
    async queryPointers(paths: string[]): Promise<Map<string, LfsPointerFields>> {
      const entries = await callRpc("queryPointers", paths);
      return new Map(entries);
    },
    async queryDerived<T = unknown>(storeName: string, request: DerivedStoreQueryRequest): Promise<T[] | number> {
      return callRpc("queryDerived", storeName, request) as Promise<T[] | number>;
    },
    updateProviders(mtlsHeaders, agePrivateKey) {
      if (!worker) return;
      postToWorker({ type: "providers", mtlsHeaders, agePrivateKey });
    },
    updateVisibility(hidden) {
      if (!worker) return;
      postToWorker({ type: "visibility", hidden });
    },
  };
};
