import { Buffer } from "buffer";
import { SyncEngine } from "./syncEngine";
import { ManifestRegistry } from "./manifestRegistry";
import { ManifestDatabase, type DerivedStoreQueryRequest } from "./manifestDatabase";
import { timelineMonthCountsStore } from "./timelineDerivedStores";
import {
  SyncWorkerInboundMessage,
  SyncWorkerOutboundMessage,
  SyncWorkerRpcMessage,
  SerializableManifestRegistration,
} from "./workerProtocol";
import type { ManifestQueryIdentity, ManifestQueryRequest } from "./manifestDatabase";
import { parseManifest } from "../../lib/manifest";

// Provides Buffer in worker scope because isomorphic-git expects it in browser runtimes.
if (!("Buffer" in globalThis)) {
  (globalThis as typeof globalThis & { Buffer: typeof Buffer }).Buffer = Buffer;
}

let syncEngine: SyncEngine | null = null;
let manifestDb: ManifestDatabase | null = null;
let mtlsHeaders: Record<string, string> | null = null;
let agePrivateKey: string | null = null;
let hidden = false;
let workerRegistry = new ManifestRegistry();

// Sends one typed message back to the main thread.
const postToMain = (message: SyncWorkerOutboundMessage): void => {
  postMessage(message);
};


// Executes one RPC method on SyncEngine and returns the typed result.
const runRpc = async (message: SyncWorkerRpcMessage): Promise<unknown> => {
  if (!syncEngine) {
    throw new Error("Sync worker is not initialized.");
  }
  switch (message.method) {
    case "bootstrapFromCache":
      return syncEngine.bootstrapFromCache();
    case "bootstrap":
      await syncEngine.bootstrap();
      return;
    case "syncNow":
      await syncEngine.syncNow(message.args[0] as "startup" | "manual" | "poll");
      return;
    case "setUserPeriodicSyncPaused":
      syncEngine.setUserPeriodicSyncPaused(message.args[0] as boolean);
      return;
    case "setSyncIntervalMs":
      syncEngine.setSyncIntervalMs(message.args[0] as number);
      return;
    case "stop":
      syncEngine.stop();
      return;
    case "onVisibilityRegained":
      await syncEngine.onVisibilityRegained();
      return;
    case "hardResetToRemoteAfterPermission":
      await syncEngine.hardResetToRemoteAfterPermission();
      return;
    case "rewindToCommitAndPausePolling":
      await syncEngine.rewindToCommitAndPausePolling(message.args[0] as string);
      return;
    case "forwardToRemoteHeadAndResumePolling":
      await syncEngine.forwardToRemoteHeadAndResumePolling();
      return;
    case "listRecentLocalCommits":
      return syncEngine.listRecentLocalCommits(message.args[0] as number | undefined);
    case "readTrackedRemoteHeadCommitHashOrNull":
      return syncEngine.readTrackedRemoteHeadCommitHashOrNull();
    case "probeOnboardingAuthorization":
      return syncEngine.probeOnboardingAuthorization();
    case "query":
      if (!manifestDb) throw new Error("Manifest database not initialized.");
      return manifestDb.query(
        message.args[0] as ManifestQueryIdentity,
        message.args[1] as ManifestQueryRequest,
      );
    case "queryPointers": {
      if (!manifestDb) throw new Error("Manifest database not initialized.");
      const pointerMap = await manifestDb.queryPointers(message.args[0] as string[]);
      return [...pointerMap.entries()];
    }
    case "queryDerived": {
      if (!manifestDb) throw new Error("Manifest database not initialized.");
      return manifestDb.queryDerived(
        message.args[0] as string,
        message.args[1] as DerivedStoreQueryRequest,
      );
    }
  }
};

// Builds a fresh registry from serialized descriptors, providing worker-local decode/primaryKey
// functions so the SyncEngine can process manifests without serializing closures across the boundary.
const buildRegistryFromDescriptors = (descriptors: SerializableManifestRegistration[]): ManifestRegistry => {
  const registry = new ManifestRegistry();
  for (const desc of descriptors) {
    registry.register({
      apiVersion: desc.apiVersion,
      kind: desc.kind,
      decode: (rawYaml: string) => parseManifest(rawYaml),
      primaryKey: (decoded: any) =>
        `${decoded.metadata?.deviceSpace ?? "unknown"}/${decoded.metadata?.name ?? "unknown"}`,
      indexes: desc.indexes,
    });
  }
  return registry;
};

// Routes inbound worker messages to initialization, provider updates, or RPC execution.
const handleMessage = async (message: SyncWorkerInboundMessage): Promise<void> => {
  if (message.type === "init") {
    syncEngine?.stop();
    manifestDb?.close();
    workerRegistry = buildRegistryFromDescriptors(message.registrations ?? []);
    manifestDb = new ManifestDatabase(
      workerRegistry.allRegistrations(),
      [timelineMonthCountsStore],
      message.syncDatabaseName ?? "gitdb-manifests-v1",
    );
    syncEngine = new SyncEngine(
      message.syncEngineConfig,
      workerRegistry,
      manifestDb,
      (snapshot) => postToMain({ type: "snapshot", data: snapshot }),
      () => mtlsHeaders,
      () => agePrivateKey,
      () => hidden,
    );
    syncEngine.onManifestChange((change) => {
      postToMain({ type: "manifestChange", data: change });
    });
    postToMain({ type: "ready" });
    return;
  }

  if (message.type === "providers") {
    mtlsHeaders = message.mtlsHeaders;
    agePrivateKey = message.agePrivateKey;
    return;
  }

  if (message.type === "visibility") {
    hidden = message.hidden;
    return;
  }

  try {
    const result = await runRpc(message);
    postToMain({
      type: "rpc-result",
      callId: message.callId,
      method: message.method,
      result,
    });
  } catch (error) {
    postToMain({
      type: "rpc-result",
      callId: message.callId,
      method: message.method,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};

// Keeps the worker as the long-lived sync runtime that serves RPC calls from the UI thread.
globalThis.addEventListener("message", (event: MessageEvent<SyncWorkerInboundMessage>) => {
  void handleMessage(event.data);
});

// Exposes the worker registry so the main thread can push registration descriptors.
export { workerRegistry };
