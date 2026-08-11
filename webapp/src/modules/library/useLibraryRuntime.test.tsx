import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useLayoutEffect, useRef, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SetupMode } from "../onboarding/useOnboardingFlow";
import { useLibraryRuntime } from "./useLibraryRuntime";

const gitdbMocks = vi.hoisted(() => ({
  mockCreateGitdbWorker: vi.fn(),
  mockClearIdentityRecord: vi.fn(),
}));
const RESET_CLONE_DEPTH_SESSION_KEY = "replycant-reset-initial-clone-depth";
const SETUP_CONFIG_STORAGE_KEY = "replycant.setup.config";

vi.mock("../gitdb", () => ({
  createGitdbWorker: gitdbMocks.mockCreateGitdbWorker,
  clearIdentityRecord: gitdbMocks.mockClearIdentityRecord,
  IDENTITY_STORAGE_KEY: "replycant-identity",
  deriveBinaryPointerPath: vi.fn().mockReturnValue("/mock/pointer/path"),
}));

const mockEngine = {
  initialize: vi.fn(),
  bootstrapFromCache: vi.fn(),
  bootstrap: vi.fn(),
  updateProviders: vi.fn(),
  updateVisibility: vi.fn(),
  shutdown: vi.fn(),
  onVisibilityRegained: vi.fn(),
  probeOnboardingAuthorization: vi.fn(),
  syncNow: vi.fn(),
  setUserPeriodicSyncPaused: vi.fn(),
  setSyncIntervalMs: vi.fn(),
  listRecentLocalCommits: vi.fn(),
  hardResetToRemoteAfterPermission: vi.fn(),
  readTrackedRemoteHeadCommitHashOrNull: vi.fn(),
  forwardToRemoteHeadAndResumePolling: vi.fn(),
  rewindToCommitAndPausePolling: vi.fn(),
  queryDerived: vi.fn().mockResolvedValue([]),
  queryPointers: vi.fn().mockResolvedValue(new Map()),
  query: vi.fn().mockResolvedValue([]),
};

// Builds deterministic Original records so tests can focus on window offset and reload behavior.
const buildOriginalRecords = (prefix: string, startDay = 1) =>
  Array.from({ length: 100 }, (_, i) => {
    const day = ((startDay + i) % 28) + 1;
    return {
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/${prefix}-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `${prefix}-${i}` },
        spec: {
          id: `${prefix}-${i}`,
          sha256: `sha-${prefix}-${i}`,
          path: `/tmp/${prefix}-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String(day).padStart(2, "0")}T00:00:00Z`,
        },
      },
    };
  });

// Builds one deterministic Original record so tests can target exact range checks.
const buildOriginalRecord = (name: string, takenAt: string) => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  key: `device/${name}`,
  manifest: {
    apiVersion: "media.replycant.com/v1alpha1",
    kind: "Original",
    metadata: { deviceSpace: "device", name },
    spec: {
      id: name,
      sha256: `sha-${name}`,
      path: `/tmp/${name}.jpg`,
      mediaType: "photo",
      mimeType: "image/jpeg",
      width: 1000,
      height: 800,
      takenAt,
    },
  },
});

// Builds a ThumbnailSet linked to one Original so thumbnail refresh behavior can be asserted.
const buildThumbnailRecord = (name: string, originalRef: string, sha256: string) => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "ThumbnailSet",
  key: `device/media.replycant.com/v1alpha1/ThumbnailSet/${name}`,
  manifest: {
    apiVersion: "media.replycant.com/v1alpha1",
    kind: "ThumbnailSet",
    metadata: { deviceSpace: "device", name },
    spec: {
      originalRef,
      thumbnails: [{ name, sha256, width: 280, height: 280 }],
    },
  },
});

// Builds a stable ascending timeline window so tests can reason about cursor boundaries.
const buildSequentialOriginalRecords = (prefix: string, count: number, startMinute = 0) =>
  Array.from({ length: count }, (_, i) => {
    const takenAt = new Date(Date.UTC(2026, 2, 15, 0, startMinute + i, 0)).toISOString();
    return buildOriginalRecord(`${prefix}-${i}`, takenAt);
  });

// Exposes runtime actions so tests can verify sync behavior without rendering timeline UI.
const RuntimeHarness = ({ initialMode }: { initialMode: SetupMode }) => {
  const [setupMode, setSetupMode] = useState<SetupMode>(initialMode);
  const runtime = useLibraryRuntime({
    setupMode,
    rehydrationKey: 0,
    mtlsHeaders: null,
    agePrivateKeyBase64: null,
    setSetupMode,
    setSetupError: vi.fn(),
  });
  const loadedItemsRefChangeCountRef = useRef(0);
  const previousLoadedItemsRef = useRef(runtime.timelineWindow.loadedItems);
  if (previousLoadedItemsRef.current !== runtime.timelineWindow.loadedItems) {
    loadedItemsRefChangeCountRef.current += 1;
    previousLoadedItemsRef.current = runtime.timelineWindow.loadedItems;
  }

  return (
    <div>
      <div data-testid="runtime-error">{runtime.snapshot.error ?? ""}</div>
      <div data-testid="loaded-offset">{String(runtime.timelineWindow.loadedOffset)}</div>
      <div data-testid="loaded-items-count">{String(runtime.timelineWindow.loadedItems.length)}</div>
      <div data-testid="loaded-items-ref-change-count">{String(loadedItemsRefChangeCountRef.current)}</div>
      <div data-testid="first-loaded-key">{runtime.timelineWindow.loadedItems[0]?.key ?? ""}</div>
      <div data-testid="last-loaded-key">{runtime.timelineWindow.loadedItems.at(-1)?.key ?? ""}</div>
      <div data-testid="first-loaded-thumbnail-url">{runtime.timelineWindow.loadedItems[0]?.thumbnailUrl ?? ""}</div>
      <button type="button" onClick={() => void runtime.handleSyncNow()}>
        sync-now
      </button>
      <button type="button" onClick={() => runtime.seekToIndex(5000)}>
        seek-5000
      </button>
      <button type="button" onClick={() => runtime.seekToIndex(5072)}>
        seek-5072
      </button>
      <button type="button" onClick={() => runtime.loadNewerPage()}>
        load-newer
      </button>
      <button type="button" onClick={() => runtime.loadOlderPage()}>
        load-older
      </button>
      <button type="button" onClick={() => void runtime.wipeReplycantState(20)}>
        wipe-custom-depth
      </button>
      <button type="button" onClick={() => void runtime.wipeReplycantState()}>
        wipe-default-depth
      </button>
      <button
        type="button"
        onClick={() => void runtime.wipeReplycantState(undefined, undefined, true)}
      >
        wipe-server-config
      </button>
      <button type="button" onClick={() => void runtime.wipeReplycantState(undefined, true)}>
        wipe-keypair
      </button>
      <button type="button" onClick={() => void runtime.handleJumpToCommit("abc123")}>
        jump-short-head
      </button>
      <button type="button" onClick={() => void runtime.handleJumpToCommit("65035d7")}>
        jump-short-non-head
      </button>
    </div>
  );
};

// Forces initialization in layout phase so tests can catch credentials that are only populated in passive effects.
const RuntimeLayoutInitHarness = ({
  initialMode,
  mtlsHeaders,
  agePrivateKeyBase64,
}: {
  initialMode: SetupMode;
  mtlsHeaders: Record<string, string> | null;
  agePrivateKeyBase64: string | null;
}) => {
  const [setupMode, setSetupMode] = useState<SetupMode>(initialMode);
  const runtime = useLibraryRuntime({
    setupMode,
    rehydrationKey: 0,
    mtlsHeaders,
    agePrivateKeyBase64,
    setSetupMode,
    setSetupError: vi.fn(),
  });

  // Triggers engine creation before passive effects so provider refs must already reflect current props.
  useLayoutEffect(() => {
    void runtime.initializeEngine();
  }, [runtime.initializeEngine]);

  return <div data-testid="layout-init-harness">{runtime.snapshot.error ?? ""}</div>;
};

// Exercises repeated startup calls that React StrictMode can trigger during dev reloads.
const RuntimeDoubleInitHarness = ({ initialMode }: { initialMode: SetupMode }) => {
  const [setupMode, setSetupMode] = useState<SetupMode>(initialMode);
  const runtime = useLibraryRuntime({
    setupMode,
    rehydrationKey: 0,
    mtlsHeaders: null,
    agePrivateKeyBase64: null,
    setSetupMode,
    setSetupError: vi.fn(),
  });

  useLayoutEffect(() => {
    void runtime.initializeEngine();
    void runtime.initializeEngine();
  }, [runtime.initializeEngine]);

  return <div data-testid="double-init-harness">{setupMode}</div>;
};

describe("useLibraryRuntime", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    sessionStorage.clear();
    localStorage.clear();
    Object.defineProperty(window, "indexedDB", {
      configurable: true,
      value: {
        deleteDatabase: vi.fn().mockImplementation(() => {
          const request: {
            onsuccess: (() => void) | null;
            onerror: (() => void) | null;
            onblocked: (() => void) | null;
            error: Error | null;
          } = {
            onsuccess: null,
            onerror: null,
            onblocked: null,
            error: null,
          };
          queueMicrotask(() => request.onsuccess?.());
          return request;
        }),
        databases: vi.fn().mockResolvedValue([]),
      },
    });
    mockEngine.initialize.mockResolvedValue(undefined);
    mockEngine.bootstrapFromCache.mockResolvedValue({ hasCachedData: false });
    mockEngine.bootstrap.mockResolvedValue(undefined);
    mockEngine.syncNow.mockResolvedValue(undefined);
    mockEngine.setUserPeriodicSyncPaused.mockResolvedValue(undefined);
    mockEngine.setSyncIntervalMs.mockResolvedValue(undefined);
    mockEngine.listRecentLocalCommits.mockResolvedValue([]);
    mockEngine.probeOnboardingAuthorization.mockResolvedValue({ status: "pending_authorization" });
    mockEngine.queryDerived.mockResolvedValue([]);
    // Returns complete encryption metadata so timeline URLs never fall back to plaintext sha256.
    mockEngine.queryPointers.mockImplementation(async (paths: string[]) => {
      const map = new Map();
      for (const path of paths) {
        map.set(path, {
          oid: `oid-${path}`,
          size: 100,
          kekEpoch: 1,
          wrappedDek: "wrapped",
          dekBase64: "ZGVr",
        });
      }
      return map;
    });
    gitdbMocks.mockCreateGitdbWorker.mockReturnValue(mockEngine);
  });

  it("runs manual sync through the engine", async () => {
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(mockEngine.initialize).toHaveBeenCalledTimes(1);
    expect(mockEngine.syncNow).toHaveBeenCalledWith("manual");
  });

  it("deduplicates concurrent engine initialization calls", async () => {
    render(<RuntimeDoubleInitHarness initialMode="create" />);

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(mockEngine.initialize).toHaveBeenCalledTimes(1);
  });

  it("surfaces manual sync failures in snapshot state", async () => {
    mockEngine.syncNow.mockRejectedValue(new Error("network"));
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(screen.getByTestId("runtime-error")).toHaveTextContent("Manual sync failed: network"));
  });

  it("treats a tracked-head short hash as forward-to-head", async () => {
    mockEngine.readTrackedRemoteHeadCommitHashOrNull.mockResolvedValue("abc123def4567890");
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "jump-short-head" }));
    });
    await waitFor(() => expect(mockEngine.forwardToRemoteHeadAndResumePolling).toHaveBeenCalledTimes(1));
    expect(mockEngine.rewindToCommitAndPausePolling).not.toHaveBeenCalled();
  });

  it("falls back to rewind when forward-to-head fails for short hash", async () => {
    mockEngine.readTrackedRemoteHeadCommitHashOrNull.mockResolvedValue("abc123def4567890");
    mockEngine.forwardToRemoteHeadAndResumePolling.mockRejectedValue(new Error("Could not read ref"));
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "jump-short-head" }));
    });
    await waitFor(() => expect(mockEngine.forwardToRemoteHeadAndResumePolling).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(mockEngine.rewindToCommitAndPausePolling).toHaveBeenCalledWith("abc123"));
    expect(screen.getByTestId("runtime-error")).toHaveTextContent("");
  });

  it("resolves short non-head hash from known commits before rewind", async () => {
    const headHash = "638b630207925f95635ce1fa1eab63678689827f";
    const nonHeadHash = "65035d718af00b631ad13df3d84839e4b6938f9f";
    mockEngine.readTrackedRemoteHeadCommitHashOrNull.mockResolvedValue(headHash);
    mockEngine.listRecentLocalCommits.mockResolvedValue([
      { hash: headHash, message: "head", authoredAt: "2026-01-01T00:00:00Z" },
      { hash: nonHeadHash, message: "prev", authoredAt: "2025-12-31T00:00:00Z" },
    ]);
    render(<RuntimeHarness initialMode="ready" />);
    await waitFor(() => expect(mockEngine.listRecentLocalCommits).toHaveBeenCalled());
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "jump-short-non-head" }));
    });
    await waitFor(() => expect(mockEngine.rewindToCommitAndPausePolling).toHaveBeenCalledWith(nonHeadHash));
    expect(screen.getByTestId("runtime-error")).toHaveTextContent("");
  });

  it("stores clone depth override before reload when wipe is called with custom depth", async () => {
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "wipe-custom-depth" }));
    });
    await waitFor(() => expect(sessionStorage.getItem(RESET_CLONE_DEPTH_SESSION_KEY)).toBe("20"));
  });

  it("clears clone depth override before reload when wipe is called without custom depth", async () => {
    sessionStorage.setItem(RESET_CLONE_DEPTH_SESSION_KEY, "99");
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "wipe-default-depth" }));
    });
    await waitFor(() => expect(sessionStorage.getItem(RESET_CLONE_DEPTH_SESSION_KEY)).toBeNull());
  });

  it("clears persisted setup config when wipe is called with wipeServerConfig option", async () => {
    localStorage.setItem(SETUP_CONFIG_STORAGE_KEY, "{\"serverUrl\":\"http://replycant.local:8080\"}");
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "wipe-server-config" }));
    });
    await waitFor(() => expect(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY)).toBeNull());
  });

  it("does not clear identity when wipe omits wipeKeypair", async () => {
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "wipe-default-depth" }));
    });
    await waitFor(() => expect(sessionStorage.getItem(RESET_CLONE_DEPTH_SESSION_KEY)).toBeNull());
    expect(gitdbMocks.mockClearIdentityRecord).not.toHaveBeenCalled();
  });

  it("clears identity when wipe sets wipeKeypair", async () => {
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "wipe-keypair" }));
    });
    await waitFor(() => expect(gitdbMocks.mockClearIdentityRecord).toHaveBeenCalledTimes(1));
  });

  it("exposes current credentials to createGitdb providers during first layout-phase initialization", async () => {
    const mtlsHeaders = {
      "x-replycant-cert-fingerprint": "cert-fp",
      "x-replycant-device-uuid": "device-uuid",
    };
    const agePrivateKeyBase64 = "AGE-SECRET-KEY-BASE64";
    let providerHeadersAtCreate: Record<string, string> | null = null;
    let providerAgeKeyAtCreate: string | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      mtlsHeadersProvider?: () => Record<string, string> | null;
      agePrivateKeyProvider?: () => string | null;
    }) => {
      providerHeadersAtCreate = options?.mtlsHeadersProvider?.() ?? null;
      providerAgeKeyAtCreate = options?.agePrivateKeyProvider?.() ?? null;
      return mockEngine;
    });

    render(
      <RuntimeLayoutInitHarness
        initialMode="create"
        mtlsHeaders={mtlsHeaders}
        agePrivateKeyBase64={agePrivateKeyBase64}
      />,
    );

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(providerHeadersAtCreate).toEqual(mtlsHeaders);
    expect(providerAgeKeyAtCreate).toBe(agePrivateKeyBase64);
  });

  it("switches to ready from cached data and starts startup sync in background", async () => {
    mockEngine.bootstrapFromCache.mockResolvedValue({ hasCachedData: true });
    render(<RuntimeHarness initialMode="rehydrating" />);

    await waitFor(() => expect(mockEngine.bootstrapFromCache).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(mockEngine.syncNow).toHaveBeenCalledWith("startup"));
    expect(mockEngine.bootstrap).not.toHaveBeenCalled();
    expect(mockEngine.syncNow).not.toHaveBeenCalledWith("manual");
  });

  it("seekToIndex sets timeline window offset to the target month globalOffset", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const marchRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/photo-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `photo-${i}` },
        spec: {
          id: `id-${i}`,
          sha256: `sha-${i}`,
          path: `/tmp/photo-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-01T00:00:00Z"
      ) {
        return marchRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5000" }));
    });

    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5000"));
  });

  it("seekToIndex uses cursor skip and lands on exact requested index", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const marchRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/exact-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `exact-${i}` },
        spec: {
          id: `exact-${i}`,
          sha256: `sha-exact-${i}`,
          path: `/tmp/exact-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      skip?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.skip === 72
      ) {
        return marchRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5072" }));
    });

    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));
  });

  it("seekToIndex clears window immediately before async target load resolves", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const initialRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/initial-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `initial-${i}` },
        spec: {
          id: `initial-${i}`,
          sha256: `sha-initial-${i}`,
          path: `/tmp/initial-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-04-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));

    const marchRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/seek-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `seek-${i}` },
        spec: {
          id: `seek-${i}`,
          sha256: `sha-seek-${i}`,
          path: `/tmp/seek-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));

    let resolveSeekQuery: ((records: typeof marchRecords) => void) | null = null;
    const seekQueryPromise = new Promise<typeof marchRecords>((resolve) => {
      resolveSeekQuery = resolve;
    });

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "prev"
      ) {
        return initialRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-01T00:00:00Z"
      ) {
        return seekQueryPromise;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5000" }));
    });
    expect(screen.getByTestId("loaded-offset")).toHaveTextContent("0");
    expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("0");

    await act(async () => {
      resolveSeekQuery?.(marchRecords);
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5000"));
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));
  });

  it("restores first fullReplace window from hash anchor takenAt", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const marchRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/hash-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `hash-${i}` },
        spec: {
          id: `hash-${i}`,
          sha256: `sha-hash-${i}`,
          path: `/tmp/hash-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
      ) {
        return marchRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });

    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });

    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));
  });

  it("discards stale pagination result when seek starts during in-flight loadNewer", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const anchorRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/anchor-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `anchor-${i}` },
        spec: {
          id: `anchor-${i}`,
          sha256: `sha-anchor-${i}`,
          path: `/tmp/anchor-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));
    const seekRecords = Array.from({ length: 100 }, (_, i) => ({
      ...anchorRecords[i],
      key: `device/seek-target-${i}`,
      manifest: {
        ...anchorRecords[i].manifest,
        metadata: { deviceSpace: "device", name: `seek-target-${i}` },
      },
    }));
    const newerRecords = Array.from({ length: 100 }, (_, i) => ({
      ...anchorRecords[i],
      key: `device/newer-${i}`,
      manifest: {
        ...anchorRecords[i].manifest,
        metadata: { deviceSpace: "device", name: `newer-${i}` },
      },
    }));

    let resolveNewer: ((records: typeof newerRecords) => void) | null = null;
    const newerPromise = new Promise<typeof newerRecords>((resolve) => {
      resolveNewer = resolve;
    });

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      skip?: number;
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
        && !query.skip
        && query.limit === 100
      ) {
        return anchorRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.skip === 72
        && query.limit === 100
      ) {
        return seekRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.skip === 72
        && query.limit === 100
      ) {
        return seekRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.limit === 120
      ) {
        return newerPromise;
      }
      return [];
    });

    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5000"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5072" }));
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));

    await act(async () => {
      resolveNewer?.(newerRecords);
    });

    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));
  });

  it("keeps latest seek result when overlapping seeks resolve out of order", async () => {
    let onManifestChange: ((change: { type: "fullReplace" }) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: { type: "fullReplace" }) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });

    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const firstSeekRecords = Array.from({ length: 100 }, (_, i) => ({
      apiVersion: "media.replycant.com/v1alpha1",
      kind: "Original",
      key: `device/first-${i}`,
      manifest: {
        apiVersion: "media.replycant.com/v1alpha1",
        kind: "Original",
        metadata: { deviceSpace: "device", name: `first-${i}` },
        spec: {
          id: `first-${i}`,
          sha256: `sha-first-${i}`,
          path: `/tmp/first-${i}.jpg`,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 1000,
          height: 800,
          takenAt: `2026-03-${String((i % 28) + 1).padStart(2, "0")}T00:00:00Z`,
        },
      },
    }));
    const secondSeekRecords = Array.from({ length: 100 }, (_, i) => ({
      ...firstSeekRecords[i],
      key: `device/second-${i}`,
      manifest: {
        ...firstSeekRecords[i].manifest,
        metadata: { deviceSpace: "device", name: `second-${i}` },
      },
    }));

    let resolveFirstSeek: ((records: typeof firstSeekRecords) => void) | null = null;
    let resolveSecondSeek: ((records: typeof secondSeekRecords) => void) | null = null;
    const firstSeekPromise = new Promise<typeof firstSeekRecords>((resolve) => {
      resolveFirstSeek = resolve;
    });
    const secondSeekPromise = new Promise<typeof secondSeekRecords>((resolve) => {
      resolveSecondSeek = resolve;
    });

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      skip?: number;
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "prev"
      ) {
        return firstSeekRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.skip === 0
        && query.limit === 100
      ) {
        return firstSeekPromise;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.skip === 72
        && query.limit === 100
      ) {
        return secondSeekPromise;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    expect(onManifestChange).toBeTruthy();

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5000" }));
      fireEvent.click(screen.getByRole("button", { name: "seek-5072" }));
    });

    await act(async () => {
      resolveSecondSeek?.(secondSeekRecords);
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));

    await act(async () => {
      resolveFirstSeek?.(firstSeekRecords);
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));
  });

  it("reloads the current sparse window after incremental changes", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const initialRecords = buildOriginalRecords("initial");
    const reloadedRecords = buildOriginalRecords("reloaded", 8);
    let anchorCursorLoadCount = 0;
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower?.startsWith("2026-03-")
      ) {
        anchorCursorLoadCount += 1;
        return anchorCursorLoadCount === 1 ? initialRecords : reloadedRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/initial-"));

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [reloadedRecords[0]],
          removed: [],
          updated: [],
        },
      });
    });

    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/reloaded-"));
  });

  it("keeps the current sparse window reference when incremental reload has no key changes", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const stableRecords = buildOriginalRecords("stable-window");
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower?.startsWith("2026-03-")
      ) {
        return stableRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/stable-window-"));

    const refChangeCountAfterFullReplace = Number(
      screen.getByTestId("loaded-items-ref-change-count").textContent ?? "0",
    );

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: { added: [], removed: [], updated: [] },
      });
    });

    await waitFor(() => {
      expect(screen.getByTestId("loaded-items-ref-change-count")).toHaveTextContent(
        String(refChangeCountAfterFullReplace),
      );
    });
  });

  it("reloads current sparse window when a loaded item's thumbnail record changes", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const initialRecords = buildSequentialOriginalRecords("thumb-anchor", 100);
    const thumbOriginalRef = "device/media.replycant.com/v1alpha1/Original/thumb-anchor-0";
    let useUpdatedThumb = false;
    let anchorCursorLoadCount = 0;
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      equals?: string;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower?.startsWith("2026-03-")
      ) {
        anchorCursorLoadCount += 1;
        return initialRecords;
      }
      if (
        identity.kind === "ThumbnailSet"
        && query.type === "index"
        && query.indexName === "byOriginalRef"
        && query.equals === thumbOriginalRef
      ) {
        return [
          buildThumbnailRecord(
            "thumb-anchor-0",
            thumbOriginalRef,
            useUpdatedThumb ? "thumb-sha-new" : "thumb-sha-old",
          ),
        ];
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/thumb-anchor-"));

    const initialThumbUrl = screen.getByTestId("first-loaded-thumbnail-url").textContent;
    const previousThumb = buildThumbnailRecord("thumb-anchor-0", thumbOriginalRef, "thumb-sha-old");
    const currentThumb = buildThumbnailRecord("thumb-anchor-0", thumbOriginalRef, "thumb-sha-new");
    useUpdatedThumb = true;
    // Pointer OID changes with the thumbnail bytes so the URL updates after reload.
    mockEngine.queryPointers.mockImplementation(async (paths: string[]) => {
      const map = new Map();
      for (const path of paths) {
        map.set(path, {
          oid: "oid-thumb-sha-new",
          size: 100,
          kekEpoch: 1,
          wrappedDek: "wrapped",
          dekBase64: "ZGVr",
        });
      }
      return map;
    });

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [],
          removed: [],
          updated: [{ previous: previousThumb, current: currentThumb }],
        },
      });
    });

    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/thumb-anchor-"));
    await waitFor(() => {
      expect(screen.getByTestId("first-loaded-thumbnail-url").textContent).not.toBe(initialThumbUrl);
    });
  });

  it("preserves loaded span length after incremental refresh when window grew beyond page size", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4200, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const anchorRecords = buildSequentialOriginalRecords("span-anchor", 100);
    const newerRecords = Array.from({ length: 20 }, (_, i) =>
      buildOriginalRecord(`span-newer-${i}`, `2026-03-30T00:${String(i).padStart(2, "0")}:00Z`),
    );
    const reloadedRecords = [...anchorRecords, ...newerRecords];

    let incrementalRefreshStarted = false;
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
      ) {
        if (query.limit === 120) {
          if (incrementalRefreshStarted) return reloadedRecords.slice(0, 120);
          return newerRecords;
        }
        return anchorRecords.slice(0, query.limit ?? 100);
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("120"));

    await act(async () => {
      incrementalRefreshStarted = true;
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [buildOriginalRecord("span-new-media", "2026-03-20T10:00:00Z")],
          removed: [],
          updated: [],
        },
      });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("120"));
  });

  it("keeps loaded items reference stable for newer incremental additions outside current window", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const stableRecords = buildOriginalRecords("stable-window");
    const beforeReloadCursorQueryCount = () => mockEngine.query.mock.calls.filter(([, query]) =>
      query?.type === "cursor" && query?.direction === "next" && query?.range?.lower === "2026-03-15T00:00:00Z"
    ).length;
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
      ) {
        return stableRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/stable-window-"));
    const refChangesBeforeIncremental = Number(screen.getByTestId("loaded-items-ref-change-count").textContent ?? "0");
    const cursorQueriesBeforeIncremental = beforeReloadCursorQueryCount();

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [buildOriginalRecord("outside-newer", "2026-04-01T00:00:00Z")],
          removed: [],
          updated: [],
        },
      });
    });

    await waitFor(() => {
      expect(Number(screen.getByTestId("loaded-items-ref-change-count").textContent ?? "0"))
        .toBe(refChangesBeforeIncremental);
    });
    expect(beforeReloadCursorQueryCount()).toBe(cursorQueriesBeforeIncremental);
  });

  it("updates only offset for older incremental additions outside current window", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const stableRecords = buildSequentialOriginalRecords("offset-window", 100);
    const matchingReloadCursorQueryCount = () => mockEngine.query.mock.calls.filter(([, query]) =>
      query?.type === "cursor" && query?.direction === "next" && query?.range?.lower === "2026-03-15T00:00:00Z"
    ).length;
    let countCalls = 0;
    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        countCalls += 1;
        return countCalls >= 2 ? 73 : 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
      ) {
        return stableRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));
    const offsetBeforeIncremental = Number(screen.getByTestId("loaded-offset").textContent ?? "0");
    const refChangesBeforeIncremental = Number(screen.getByTestId("loaded-items-ref-change-count").textContent ?? "0");
    const cursorQueriesBeforeIncremental = matchingReloadCursorQueryCount();

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [buildOriginalRecord("outside-older", "2026-02-10T00:00:00Z")],
          removed: [],
          updated: [],
        },
      });
    });

    await waitFor(() => {
      expect(Number(screen.getByTestId("loaded-offset").textContent ?? "0")).toBe(offsetBeforeIncremental + 1);
    });
    expect(Number(screen.getByTestId("loaded-items-ref-change-count").textContent ?? "0"))
      .toBe(refChangesBeforeIncremental);
    expect(matchingReloadCursorQueryCount()).toBe(cursorQueriesBeforeIncremental);
  });

  it("keeps current timeline visible while fullReplace load is in flight", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const initialRecords = buildSequentialOriginalRecords("fullreplace-anchor", 100);
    const deferredReloadRecords = buildSequentialOriginalRecords("fullreplace-reloaded", 100, 500);
    let resolveReload: ((records: typeof deferredReloadRecords) => void) | null = null;
    const pendingReload = new Promise<typeof deferredReloadRecords>((resolve) => {
      resolveReload = resolve;
    });

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
      ) {
        return initialRecords;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "prev"
      ) {
        return pendingReload;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/fullreplace-anchor-"));
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));

    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100");
    expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/fullreplace-anchor-");

    await act(async () => {
      resolveReload?.(deferredReloadRecords);
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/fullreplace-reloaded-"));
  });

  it("ignores stale incremental reload when a newer seek reload wins", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4000, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);

    const initialRecords = buildOriginalRecords("stale-initial");
    const staleIncrementalRecords = buildOriginalRecords("stale-incremental", 10);
    const seekRecords = buildOriginalRecords("seek-wins", 20);
    let resolveIncrementalReload: ((records: ReturnType<typeof buildOriginalRecords>) => void) | null = null;
    const incrementalReloadPromise = new Promise<ReturnType<typeof buildOriginalRecords>>((resolve) => {
      resolveIncrementalReload = resolve;
    });
    let anchorCursorLoadCount = 0;

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string };
      skip?: number;
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.range?.lower === "2026-03-15T00:00:00Z"
      ) {
        anchorCursorLoadCount += 1;
        return anchorCursorLoadCount === 1 ? initialRecords : incrementalReloadPromise;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.skip === 72
        && query.limit === 100
      ) {
        return seekRecords;
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/stale-initial-"));

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: { added: [], removed: [], updated: [] },
      });
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "seek-5072" }));
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/seek-wins-"));

    await act(async () => {
      resolveIncrementalReload?.(staleIncrementalRecords);
    });
    await waitFor(() => expect(screen.getByTestId("first-loaded-key")).toHaveTextContent("device/seek-wins-"));
  });

  // Keeps a second edge load alive when the first is still in flight so commit
  // switches and rapid scroll cannot silently drop the viewport-covering page.
  it("retries loadNewerPage that arrives while another edge load is in flight", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4200, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const anchorRecords = buildSequentialOriginalRecords("retry-anchor", 100);
    const firstNewerPage = Array.from({ length: 20 }, (_, i) =>
      buildOriginalRecord(`retry-newer-a-${i}`, `2026-03-30T00:${String(i).padStart(2, "0")}:00Z`),
    );
    const secondNewerPage = Array.from({ length: 20 }, (_, i) =>
      buildOriginalRecord(`retry-newer-b-${i}`, `2026-03-30T01:${String(i).padStart(2, "0")}:00Z`),
    );

    let resolveFirstNewer: ((records: ReturnType<typeof buildOriginalRecord>[]) => void) | null = null;
    const firstNewerPromise = new Promise<ReturnType<typeof buildOriginalRecord>[]>((resolve) => {
      resolveFirstNewer = resolve;
    });
    let newerLoadCount = 0;

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string; lowerOpen?: boolean };
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.limit === 120
      ) {
        newerLoadCount += 1;
        if (newerLoadCount === 1) return firstNewerPromise;
        return secondNewerPage;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
      ) {
        return anchorRecords.slice(0, query.limit ?? 100);
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await waitFor(() => expect(newerLoadCount).toBe(1));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await act(async () => {
      resolveFirstNewer?.(firstNewerPage);
    });

    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("140"));
    expect(screen.getByTestId("last-loaded-key")).toHaveTextContent("device/retry-newer-b-19");
    expect(newerLoadCount).toBeGreaterThanOrEqual(2);
  });

  // Recovers when a commit jump bumps the load generation while an edge page is
  // still in flight, so the viewport is not left on skeletons until the user scrolls.
  it("retries loadNewerPage discarded by a manifest-change generation bump", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4200, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const anchorRecords = buildSequentialOriginalRecords("gen-anchor", 100);
    const newerPage = Array.from({ length: 20 }, (_, i) =>
      buildOriginalRecord(`gen-newer-${i}`, `2026-03-30T00:${String(i).padStart(2, "0")}:00Z`),
    );

    let resolveFirstNewer: ((records: ReturnType<typeof buildOriginalRecord>[]) => void) | null = null;
    const firstNewerPromise = new Promise<ReturnType<typeof buildOriginalRecord>[]>((resolve) => {
      resolveFirstNewer = resolve;
    });
    let newerLoadCount = 0;

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string; lowerOpen?: boolean };
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        return 72;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.limit === 120
      ) {
        newerLoadCount += 1;
        if (newerLoadCount === 1) return firstNewerPromise;
        return newerPage;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
      ) {
        return anchorRecords.slice(0, query.limit ?? 100);
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("100"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await waitFor(() => expect(newerLoadCount).toBe(1));

    // Outside-newer addition bumps the generation without rewriting the loaded window.
    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [buildOriginalRecord("gen-outside-newer", "2026-04-01T00:00:00Z")],
          removed: [],
          updated: [],
        },
      });
    });

    await act(async () => {
      resolveFirstNewer?.(newerPage);
    });

    await waitFor(() => expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("120"));
    expect(screen.getByTestId("last-loaded-key")).toHaveTextContent("device/gen-newer-19");
    expect(newerLoadCount).toBeGreaterThanOrEqual(2);
  });

  // Applies the offset correction even when a concurrent edge merge replaced
  // loadedItems, so older insertions outside the window cannot leave a stale offset.
  it("updates loadedOffset for outside-older incremental even after a concurrent page merge", async () => {
    let onManifestChange: ((change: any) => void) | null = null;
    gitdbMocks.mockCreateGitdbWorker.mockImplementation((options?: {
      onManifestChange?: (change: any) => void;
    }) => {
      onManifestChange = options?.onManifestChange ?? null;
      return mockEngine;
    });
    window.history.replaceState(null, "", "#k=item-5000&o=12&t=2026-03-15T00:00:00Z");
    mockEngine.queryDerived.mockResolvedValue([
      { monthKey: "2026-01", count: 2000, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 3000, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 4200, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    const anchorRecords = buildSequentialOriginalRecords("race-anchor", 100);
    const newerPage = Array.from({ length: 20 }, (_, i) =>
      buildOriginalRecord(`race-newer-${i}`, `2026-03-30T00:${String(i).padStart(2, "0")}:00Z`),
    );

    let resolveNewer: ((records: ReturnType<typeof buildOriginalRecord>[]) => void) | null = null;
    const newerPromise = new Promise<ReturnType<typeof buildOriginalRecord>[]>((resolve) => {
      resolveNewer = resolve;
    });
    let resolveOffsetCount: ((value: number) => void) | null = null;
    const offsetCountPromise = new Promise<number>((resolve) => {
      resolveOffsetCount = resolve;
    });
    let countCalls = 0;

    mockEngine.query.mockImplementation(async (identity: { kind?: string }, query: {
      type?: string;
      indexName?: string;
      direction?: string;
      range?: { lower?: string; upper?: string; lowerOpen?: boolean };
      limit?: number;
    }) => {
      if (
        identity.kind === "Original"
        && query.type === "count"
        && query.indexName === "byTakenAt"
        && query.range?.lower === "2026-03-01T00:00:00Z"
        && query.range?.upper?.startsWith("2026-03-15T00:00:00")
      ) {
        countCalls += 1;
        if (countCalls === 1) return 72;
        return offsetCountPromise;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
        && query.limit === 120
      ) {
        return newerPromise;
      }
      if (
        identity.kind === "Original"
        && query.type === "cursor"
        && query.indexName === "byTakenAt"
        && query.direction === "next"
      ) {
        return anchorRecords.slice(0, query.limit ?? 100);
      }
      return [];
    });

    render(<RuntimeHarness initialMode="create" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sync-now" }));
    });
    await waitFor(() => expect(gitdbMocks.mockCreateGitdbWorker).toHaveBeenCalledTimes(1));
    await act(async () => {
      onManifestChange?.({ type: "fullReplace" });
    });
    await waitFor(() => expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5072"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "load-newer" }));
    });
    await waitFor(() => expect(resolveNewer).not.toBeNull());

    await act(async () => {
      onManifestChange?.({
        type: "incremental",
        mutation: {
          added: [buildOriginalRecord("race-outside-older", "2026-02-10T00:00:00Z")],
          removed: [],
          updated: [],
        },
      });
    });
    await waitFor(() => expect(resolveOffsetCount).not.toBeNull());

    // Discarded edge load retries and merges before the deferred offset count resolves,
    // so the offset setter must apply against the post-merge window instead of bailing.
    await act(async () => {
      resolveNewer?.(newerPage);
    });
    await act(async () => {
      resolveOffsetCount?.(73);
    });

    await waitFor(() => {
      expect(screen.getByTestId("loaded-items-count")).toHaveTextContent("120");
      expect(screen.getByTestId("loaded-offset")).toHaveTextContent("5073");
    });
  });
});
