import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createGitdb } from "./gitdb";

const syncNowMock = vi.fn();

// Simulates sync engine lifecycle so callback bridge behavior can be verified without real git/network calls.
vi.mock("./syncEngine", () => ({
  SyncEngine: class {
    private readonly listener: (snapshot: any) => void;

    // Captures listener so tests can drive snapshot transitions through the gitdb callback bridge.
    constructor(_config: unknown, _registry: unknown, _db: unknown, listener: (snapshot: any) => void) {
      this.listener = listener;
    }

    // Emits start/progress/finish snapshots so callbacks can validate non-graphical progress integration.
    async syncNow(): Promise<void> {
      syncNowMock();
      this.listener({
        syncing: true,
        error: null,
        syncedCommitHash: null,
        periodicSyncPaused: false,
        periodicSyncUserEnabled: true,
        syncIntervalMs: 2000,
        isOffHead: false,
        requiresHardResetPermission: false,
        cloneProgress: { phase: "fetch", progress: 0.5 },
      });
      this.listener({
        syncing: false,
        error: null,
        syncedCommitHash: "abc123",
        periodicSyncPaused: false,
        periodicSyncUserEnabled: true,
        syncIntervalMs: 2000,
        isOffHead: false,
        requiresHardResetPermission: false,
        cloneProgress: null,
      });
    }

    async bootstrapFromCache(): Promise<{ hasCachedData: boolean }> {
      return { hasCachedData: false };
    }
    async bootstrap(): Promise<void> {}
    setUserPeriodicSyncPaused(): void {}
    setSyncIntervalMs(): void {}
    onManifestChange(): void {}
    stop(): void {}
    async onVisibilityRegained(): Promise<void> {}
    async hardResetToRemoteAfterPermission(): Promise<void> {}
    async rewindToCommitAndPausePolling(): Promise<void> {}
    async forwardToRemoteHeadAndResumePolling(): Promise<void> {}
    async listRecentLocalCommits(): Promise<any[]> {
      return [];
    }
    async readTrackedRemoteHeadCommitHashOrNull(): Promise<string | null> {
      return null;
    }
    async probeOnboardingAuthorization(): Promise<{ status: "pending_authorization" }> {
      return { status: "pending_authorization" };
    }
  },
}));

describe("createGitdb callbacks", () => {
  // Resets call history so each callback assertion measures only one sync cycle.
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("emits progress and lifecycle callbacks from snapshot updates", async () => {
    const onState = vi.fn();
    const onProgress = vi.fn();
    const onOperationStart = vi.fn();
    const onOperationComplete = vi.fn();
    const client = createGitdb({
      callbacks: {
        onState,
        onProgress,
        onOperationStart,
        onOperationComplete,
      },
    });
    await client.syncNow("manual");
    expect(syncNowMock).toHaveBeenCalled();
    expect(onState).toHaveBeenCalled();
    expect(onProgress).toHaveBeenCalledWith({
      operation: "sync",
      phase: "fetch",
      progress: 0.5,
    });
    expect(onOperationStart).toHaveBeenCalledWith({ operation: "sync" });
    expect(onOperationComplete).toHaveBeenCalledWith({ operation: "sync", syncedCommitHash: "abc123" });
  });
});
