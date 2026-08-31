import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SyncSnapshot } from "../gitdb";
import { SYNC_PROGRESS_DELAY_MS, useDelayedSyncProgress } from "./useDelayedSyncProgress";

// Builds a snapshot fixture so delay tests can override only syncing/progress fields.
const buildSnapshot = (overrides: Partial<SyncSnapshot> = {}): SyncSnapshot => ({
  syncing: false,
  error: null,
  unrecoverableError: null,
  syncedCommitHash: null,
  lastSyncAt: null,
  periodicSyncPaused: false,
  periodicSyncUserEnabled: true,
  syncIntervalMs: 2000,
  isOffHead: false,
  requiresHardResetPermission: false,
  cloneProgress: null,
  ...overrides,
});

describe("useDelayedSyncProgress", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("stays hidden while syncing is true but under the delay", () => {
    const { result } = renderHook(() => useDelayedSyncProgress(buildSnapshot({ syncing: true })));

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS - 1);
    });

    expect(result.current.visible).toBe(false);
  });

  it("becomes visible once the delay elapses while still syncing", () => {
    const { result } = renderHook(() =>
      useDelayedSyncProgress(buildSnapshot({
        syncing: true,
        cloneProgress: { phase: "Downloading", progress: 0.4 },
      })),
    );

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });

    expect(result.current.visible).toBe(true);
    expect(result.current.phase).toBe("Downloading");
    expect(result.current.progress).toBe(0.4);
  });

  it("never becomes visible when sync finishes before the delay", () => {
    const { result, rerender } = renderHook(
      ({ snapshot }) => useDelayedSyncProgress(snapshot),
      { initialProps: { snapshot: buildSnapshot({ syncing: true }) } },
    );

    act(() => {
      vi.advanceTimersByTime(1000);
    });
    rerender({ snapshot: buildSnapshot({ syncing: false }) });
    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });

    expect(result.current.visible).toBe(false);
  });

  it("does not restart the delay when cloneProgress updates mid-sync", () => {
    const { result, rerender } = renderHook(
      ({ snapshot }) => useDelayedSyncProgress(snapshot),
      {
        initialProps: {
          snapshot: buildSnapshot({
            syncing: true,
            cloneProgress: { phase: "Checking for updates", progress: 0.1 },
          }),
        },
      },
    );

    act(() => {
      vi.advanceTimersByTime(1000);
    });
    rerender({
      snapshot: buildSnapshot({
        syncing: true,
        cloneProgress: { phase: "Downloading", progress: 0.5 },
      }),
    });
    act(() => {
      vi.advanceTimersByTime(1100);
    });

    expect(result.current.visible).toBe(true);
    expect(result.current.phase).toBe("Downloading");
    expect(result.current.progress).toBe(0.5);
  });

  it("hides immediately when syncing flips false", () => {
    const { result, rerender } = renderHook(
      ({ snapshot }) => useDelayedSyncProgress(snapshot),
      {
        initialProps: {
          snapshot: buildSnapshot({
            syncing: true,
            cloneProgress: { phase: "Scanning repository", progress: 0.8 },
          }),
        },
      },
    );

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });
    expect(result.current.visible).toBe(true);

    rerender({ snapshot: buildSnapshot({ syncing: false, cloneProgress: null }) });
    expect(result.current.visible).toBe(false);
    expect(result.current.phase).toBeNull();
    expect(result.current.progress).toBeNull();
  });
});
