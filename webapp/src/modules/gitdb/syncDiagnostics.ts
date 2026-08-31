import { DatabaseVersionError, describeDatabaseVersionFailure } from "./databaseVersion";

const SYNC_PERF_PREFIX = "sync:";
let syncPerfMeasureCounter = 0;

// Provides stable wall-clock timing values for sync diagnostics across runtimes.
export const nowMs = (): number => Date.now();

// Provides monotonic timing values when performance APIs are available.
const nowPerformanceMs = (): number => {
  if (typeof performance === "undefined" || typeof performance.now !== "function") return 0;
  return performance.now();
};

// Normalizes unknown error values into stable log/debug strings.
export const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

// Prefixes sync performance labels so they are easy to filter in DevTools.
const syncPerfName = (name: string): string => `${SYNC_PERF_PREFIX}${name}`;

// Emits one performance mark when User Timing is available.
export const syncMark = (name: string): void => {
  if (typeof performance === "undefined" || typeof performance.mark !== "function") return;
  performance.mark(syncPerfName(name));
};

// Measures one timing span and returns the measured duration when supported.
export const syncMeasure = (name: string, startMarkName: string, endMarkName?: string): number | undefined => {
  if (typeof performance === "undefined" || typeof performance.measure !== "function") return undefined;
  const measureName = syncPerfName(name);
  const startName = syncPerfName(startMarkName);
  const endName = endMarkName ? syncPerfName(endMarkName) : null;
  const entry = endName
    ? performance.measure(measureName, startName, endName)
    : performance.measure(measureName, startName);
  return Number.isFinite(entry.duration) ? entry.duration : undefined;
};

// Reduces repeated mark/measure boilerplate around timed sync sections.
export const syncTimer = (name: string): { stop: () => number } => {
  syncMark(`${name}-start`);
  const startMs = nowMs();
  return {
    stop() {
      syncMark(`${name}-end`);
      syncMeasure(name, `${name}-start`, `${name}-end`);
      return nowMs() - startMs;
    },
  };
};

// Emits a synthetic measure from existing duration fields.
const syncMeasureFromDuration = (name: string, durationMs: number): void => {
  if (
    typeof performance === "undefined" ||
    typeof performance.mark !== "function" ||
    typeof performance.measure !== "function"
  ) {
    return;
  }
  const safeDurationMs = Number.isFinite(durationMs) && durationMs >= 0 ? durationMs : 0;
  const endTime = nowPerformanceMs();
  const startTime = Math.max(0, endTime - safeDurationMs);
  const id = ++syncPerfMeasureCounter;
  const startMarkName = syncPerfName(`${name}:start:${id}`);
  const endMarkName = syncPerfName(`${name}:end:${id}`);
  const measureName = syncPerfName(name);
  performance.mark(startMarkName, { startTime });
  performance.mark(endMarkName, { startTime: endTime });
  performance.measure(measureName, startMarkName, endMarkName);
};

// Emits structured sync diagnostics and mirrors duration fields into the timeline.
export const logSyncDebug = (prefix: string, event: string, fields: Record<string, unknown>): void => {
  if (typeof fields.durationMs === "number") {
    syncMeasureFromDuration(event, fields.durationMs);
  }
  const duration = typeof fields.durationMs === "number" ? `${(fields.durationMs / 1000).toFixed(2)}s ` : "";
  console.debug(`[${prefix}] ${duration}${event}`, fields);
};

// Converts transport/parser failures into actionable user-facing sync guidance.
export const describeSyncFailure = (prefix: string, error: unknown): string => {
  if (!(error instanceof Error)) {
    return "Sync failed with an unknown error.";
  }
  logSyncDebug(prefix, "describeSyncFailure-detail", {
    message: error.message,
    name: error.name,
    stack: error.stack,
  });
  if (error.name === "DatabaseVersionError" || error.message.includes("gitdb/version") || error.message.includes("gitdb database version")) {
    const guidance = error instanceof DatabaseVersionError
      ? describeDatabaseVersionFailure(error)
      : describeDatabaseVersionFailure(new DatabaseVersionError(error.message));
    return guidance;
  }
  if (error.message.includes("Cannot read properties of undefined (reading 'size')")) {
    return "Sync failed: Git response payload was invalid. Verify proxy/git server settings and retry.";
  }
  if (error.message.includes("remoteRefs is undefined")) {
    return "Sync failed: Git server did not return branch refs. Verify proxy routing, mTLS setup, and that the initial commit exists.";
  }
  if (error.message.includes("Git upstream protocol mismatch")) {
    return "Sync failed: Git proxy received a non-git response. Verify proxy target and server availability.";
  }
  return `Sync failed: ${error.message}. Check proxy/server settings and retry.`;
};

// Schedules retries with bounded exponential growth so outages do not hammer services.
export const computeBackoffMs = (failureCount: number, syncIntervalMs: number): number => {
  return Math.min(syncIntervalMs * 2 ** failureCount, Math.max(syncIntervalMs, 5 * 60_000));
};
