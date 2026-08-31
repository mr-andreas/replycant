import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SyncSnapshot } from "../modules/gitdb";
import { SYNC_PROGRESS_DELAY_MS } from "../modules/library/useDelayedSyncProgress";
import { SyncProgressBar } from "./SyncProgressBar";

// Builds a snapshot fixture so progress-bar tests can override only syncing/progress fields.
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

describe("SyncProgressBar", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders nothing before the delay elapses", () => {
    const { container } = render(
      <SyncProgressBar
        snapshot={buildSnapshot({
          syncing: true,
          cloneProgress: { phase: "Downloading", progress: 0.3 },
        })}
      />,
    );

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS - 1);
    });

    expect(container).toBeEmptyDOMElement();
  });

  it("renders a determinate fill from cloneProgress after the delay", () => {
    render(
      <SyncProgressBar
        snapshot={buildSnapshot({
          syncing: true,
          cloneProgress: { phase: "Downloading", progress: 0.42 },
        })}
      />,
    );

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });

    const bar = screen.getByRole("progressbar");
    expect(bar).toHaveAttribute("aria-valuenow", "42");
    expect(bar).toHaveAttribute("aria-label", "Downloading");
    const fill = bar.querySelector(".sync-progress-fill");
    expect(fill).toBeTruthy();
    expect(fill).not.toHaveClass("indeterminate");
    expect((fill as HTMLElement).style.width).toBe("42%");
  });

  it("uses the indeterminate class when cloneProgress is null after the delay", () => {
    render(<SyncProgressBar snapshot={buildSnapshot({ syncing: true, cloneProgress: null })} />);

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });

    const bar = screen.getByRole("progressbar");
    expect(bar).not.toHaveAttribute("aria-valuenow");
    expect(bar).toHaveAttribute("aria-valuetext", "Syncing");
    expect(bar.querySelector(".sync-progress-fill")).toHaveClass("indeterminate");
  });
});
