import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SyncSnapshot } from "../modules/gitdb";
import { SYNC_PROGRESS_DELAY_MS } from "../modules/library/useDelayedSyncProgress";
import { LibraryHeader } from "./LibraryHeader";

// Builds a snapshot fixture so header sync-bar tests can override syncing/progress only.
const buildSnapshot = (overrides: Partial<SyncSnapshot> = {}): SyncSnapshot => ({
  syncing: false,
  error: null,
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

describe("LibraryHeader", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders brand assets without the view switcher while only timeline ships", () => {
    const { container } = render(
      <LibraryHeader
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
      />,
    );

    expect(screen.getByText("Replycant")).toBeInTheDocument();
    expect(container.querySelector(".brand-logo")).toBeTruthy();
    expect(screen.queryByRole("tab")).toBeNull();
    expect(container.querySelector(".view-switcher")).toBeNull();
    expect(container.querySelector(".sync-progress")).toBeNull();
  });

  it("invokes callbacks for settings and month toggles", () => {
    const onToggleCommitPane = vi.fn();
    const onToggleMonthSidebar = vi.fn();
    render(
      <LibraryHeader
        activeView="albums"
        onSelectView={vi.fn()}
        commitPaneOpen
        onToggleCommitPane={onToggleCommitPane}
        showMonthToggle
        showMonthSidebar
        onToggleMonthSidebar={onToggleMonthSidebar}
      />,
    );

    fireEvent.click(screen.getByLabelText("Hide settings and commits"));
    fireEvent.click(screen.getByLabelText("Hide months"));

    expect(onToggleCommitPane).toHaveBeenCalled();
    expect(onToggleMonthSidebar).toHaveBeenCalled();
  });

  it("shows the sync progress bar inside the top bar after a long-running sync", () => {
    const { container } = render(
      <LibraryHeader
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        syncSnapshot={buildSnapshot({
          syncing: true,
          cloneProgress: { phase: "Downloading", progress: 0.55 },
        })}
      />,
    );

    expect(container.querySelector(".top-bar .sync-progress")).toBeNull();

    act(() => {
      vi.advanceTimersByTime(SYNC_PROGRESS_DELAY_MS);
    });

    expect(container.querySelector(".top-bar .sync-progress")).toBeTruthy();
    expect(screen.getByRole("progressbar")).toBeInTheDocument();
  });
});
