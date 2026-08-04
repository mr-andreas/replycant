import { Page } from "@playwright/test";
import { SyncPhaseTimings } from "./report";

// Clears sync persistence between iterations so each measurement starts from the same local state.
export const resetBrowserSyncState = async (page: Page): Promise<void> => {
  await page.goto("/");
  await page.evaluate(async () => {
    const deleteDatabase = async (name: string): Promise<void> =>
      new Promise((resolve) => {
        const request = indexedDB.deleteDatabase(name);
        request.onsuccess = () => resolve();
        request.onerror = () => resolve();
        request.onblocked = () => resolve();
      });
    const names = new Set<string>(["gitdb-sync-v1", "gitdb-entities", "replycant-git-v3"]);
    if (typeof indexedDB.databases === "function") {
      const databases = await indexedDB.databases();
      for (const database of databases) {
        if (!database.name) continue;
        if (database.name.startsWith("gitdb") || database.name.startsWith("replycant-git")) {
          names.add(database.name);
        }
      }
    }
    for (const name of names) {
      await deleteDatabase(name);
    }
    localStorage.clear();
    sessionStorage.clear();
  });
};

// Maps [replycant-sync] debug event names to phase timing fields so benchmark output attributes latency to stages.
const eventToPhaseField: Record<string, keyof SyncPhaseTimings> = {
  "listServerRefs-result": "listServerRefsMs",
  "clone-complete": "cloneMs",
  "fetch-complete": "fetchMs",
  "sync-pull-complete": "pullMs",
  "sync-manifest-readtree-complete": "manifestWalkMs",
  "sync-full-hydration-normalize-complete": "normalizeMs",
  "sync-full-hydration-changeset-complete": "changeSetMs",
  "sync-full-replace-cache-complete": "replaceCacheMs",
  "sync-refresh-from-cache-loaded": "cacheRefreshMs",
};

interface CapturedSyncLog {
  event: string;
  fields: Record<string, unknown>;
}

// Extracts per-phase durations from captured sync debug logs so benchmark can report where time is spent.
export const extractPhaseTimings = (debugLogs: CapturedSyncLog[]): SyncPhaseTimings => {
  const phases: SyncPhaseTimings = {};
  for (const { event, fields } of debugLogs) {
    const field = eventToPhaseField[event];
    if (field) {
      if (typeof fields.durationMs === "number") phases[field] = fields.durationMs;
      continue;
    }

    if (event === "sync-incremental-mutation-plan-built") {
      if (typeof fields.listChangedPathsDurationMs === "number") phases.incrementalChangedPathsMs = fields.listChangedPathsDurationMs;
      if (typeof fields.buildMutationDurationMs === "number") phases.incrementalBuildMutationMs = fields.buildMutationDurationMs;
    }
    if (event === "sync-incremental-cas-applied" || event === "sync-incremental-cas-stale") {
      if (typeof fields.incrementalApplyDurationMs === "number") phases.incrementalCasApplyMs = fields.incrementalApplyDurationMs;
    }
  }
  return phases;
};

// Runs one manual sync pass in the browser, capturing phase-level timing from debug logs.
export const runManualSync = async (
  page: Page,
  apiBasePath: string,
  agePrivateKeyBase64?: string,
): Promise<{ durationMs: number; syncedCommitHash: string | null; error: string | null; phases: SyncPhaseTimings }> => {
  const debugLogs: CapturedSyncLog[] = [];
  const pendingCaptures: Promise<void>[] = [];
  const onConsole = (msg: import("@playwright/test").ConsoleMessage) => {
    if (msg.type() !== "debug") return;
    const text = msg.text();
    if (!text.includes("[replycant-sync]")) return;
    const eventMatch = text.match(/\[replycant-sync\]\s+(\S+)/);
    if (!eventMatch) return;
    const event = eventMatch[1];
    const args = msg.args();
    if (args.length < 2) {
      debugLogs.push({ event, fields: {} });
      return;
    }
    const pending = args[1]
      .jsonValue()
      .then((val) => debugLogs.push({ event, fields: (val as Record<string, unknown>) ?? {} }))
      .catch(() => debugLogs.push({ event, fields: {} }));
    pendingCaptures.push(pending);
  };
  page.on("console", onConsole);

  await page.goto("/");
  const result = await page.evaluate(async ({ resolvedApiBasePath, resolvedAgePrivateKeyBase64 }) => {
    const { runtimeConfig } = await import("/src/lib/config.ts");
    const { createGitdb } = await import("/src/modules/gitdb/index.ts");
    runtimeConfig.apiBasePath = resolvedApiBasePath;
    let latestSnapshot: { syncedCommitHash: string | null; error: string | null } | null = null;
    const engine = createGitdb({
      onSnapshot: (snapshot) => {
        latestSnapshot = { syncedCommitHash: snapshot.syncedCommitHash, error: snapshot.error };
      },
      agePrivateKeyProvider: () => resolvedAgePrivateKeyBase64,
    });
    const started = performance.now();
    await engine.syncNow("manual");
    const durationMs = performance.now() - started;
    return {
      durationMs,
      syncedCommitHash: latestSnapshot?.syncedCommitHash ?? null,
      error: latestSnapshot?.error ?? null,
    };
  }, { resolvedApiBasePath: apiBasePath, resolvedAgePrivateKeyBase64: agePrivateKeyBase64 ?? null });

  page.off("console", onConsole);
  await Promise.all(pendingCaptures);
  const phases = extractPhaseTimings(debugLogs);
  return { ...result, phases };
};
