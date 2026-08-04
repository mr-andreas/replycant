import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const runtimeMock = {
  snapshot: {
    syncing: false,
    error: null,
    lastSyncAt: null,
    syncedCommitHash: null,
    periodicSyncPaused: false,
    periodicSyncUserEnabled: true,
    syncIntervalMs: 2000,
    isOffHead: false,
    requiresHardResetPermission: false,
    cloneProgress: null,
  },
  timelineItemCount: 0,
  timelineMonthIndex: [],
  timelineWindow: {
    loadedOffset: 0,
    loadedItems: [],
    olderCursor: null,
    newerCursor: null,
  },
  rewindCommits: [],
  rewindActionBusy: null,
  initializeEngine: vi.fn(),
  handleSyncNow: vi.fn(),
  handleTogglePeriodicSync: vi.fn(),
  handleChangeSyncInterval: vi.fn(),
  handleResetToRemote: vi.fn(),
  handleJumpToCommit: vi.fn().mockResolvedValue(undefined),
  wipeReplycantState: vi.fn().mockResolvedValue(undefined),
  loadOlderPage: vi.fn(),
  loadNewerPage: vi.fn(),
  seekToIndex: vi.fn(),
};

vi.mock("./modules/onboarding/useOnboardingFlow", () => ({
  useOnboardingFlow: () => ({
    setupMode: "ready",
    rehydrationKey: 0,
    mtlsHeaders: null,
    identity: null,
    setSetupMode: vi.fn(),
    setSetupError: vi.fn(),
  }),
}));

vi.mock("./modules/library/useLibraryRuntime", () => ({
  useLibraryRuntime: () => runtimeMock,
}));

vi.mock("./modules/onboarding/OnboardingGate", () => ({
  OnboardingGate: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));

vi.mock("./modules/timeline/TimelineView", () => ({
  TimelineView: ({
    activeView,
    onSelectView,
    commitPaneOpen,
    onToggleCommitPane,
    commitPane,
  }: {
    activeView: string;
    onSelectView: (view: string) => void;
    commitPaneOpen: boolean;
    onToggleCommitPane: () => void;
    commitPane: React.ReactNode;
  }) => (
    <div>
      <div>timeline-view</div>
      <div data-testid="active-view">{activeView}</div>
      <button onClick={() => onSelectView("albums")}>switch-view</button>
      <button onClick={onToggleCommitPane}>{commitPaneOpen ? "hide-commit-pane" : "show-commit-pane"}</button>
      {commitPane}
    </div>
  ),
  LibraryView: {},
}));

vi.mock("./modules/library/CollectionPlaceholderView", () => ({
  CollectionPlaceholderView: () => <div>collection-view</div>,
}));

vi.mock("./components/CommitPane", () => ({
  // Exposes commit pane callbacks so App tests can verify orchestration behavior.
  CommitPane: ({ onResetAndResync }: { onResetAndResync: () => Promise<void> }) => (
    <aside>
      commit-pane
      <button type="button" onClick={() => void onResetAndResync()}>
        reset-and-resync
      </button>
    </aside>
  ),
}));

declare global {
  interface Window {
    replycant?: {
      wipeState: (initialCloneDepth?: number, wipeKeypair?: boolean, wipeServerConfig?: boolean) => Promise<void>;
      syncToCommit: (commitHash: string) => Promise<void>;
    };
    replycantDesktop?: {
      platform: string;
      minimize: () => void;
      maximize: () => void;
      close: () => void;
      persistedLastPage: { activeView: string; hash: string } | null;
      persistLastPage: (state: { activeView: string; hash: string }) => boolean;
      identityKeyAvailable?: () => Promise<boolean>;
      identityKey?: () => Promise<string>;
      clearIdentityKey?: () => Promise<void>;
    };
  }
}

describe("App replycant helper", () => {
  beforeEach(() => {
    runtimeMock.wipeReplycantState.mockClear();
    runtimeMock.handleJumpToCommit.mockClear();
    localStorage.clear();
    delete window.replycant;
    delete window.replycantDesktop;
  });

  afterEach(() => {
    delete window.replycant;
    delete window.replycantDesktop;
  });

  it("registers window.replycant helper and removes it on unmount", async () => {
    const { unmount } = render(<App />);

    expect(window.replycant).toBeDefined();
    await window.replycant!.wipeState(20, true, true);
    expect(runtimeMock.wipeReplycantState).toHaveBeenCalledWith(20, true, true);

    await window.replycant!.syncToCommit("abc123");
    expect(runtimeMock.handleJumpToCommit).toHaveBeenCalledWith("abc123");

    unmount();
    expect(window.replycant).toBeUndefined();
  });

  it("restores saved desktop view selection", () => {
    window.replycantDesktop = {
      platform: "linux",
      minimize: vi.fn(),
      maximize: vi.fn(),
      close: vi.fn(),
      persistedLastPage: { activeView: "albums", hash: "#k=item-2" },
      persistLastPage: vi.fn(() => true),
    };

    render(<App />);

    expect(screen.queryByText("timeline-view")).toBeNull();
    expect(screen.getByText("collection-view")).toBeInTheDocument();
  });

  it("persists desktop view and hash changes", async () => {
    const persistLastPage = vi.fn(() => true);
    window.replycantDesktop = {
      platform: "linux",
      minimize: vi.fn(),
      maximize: vi.fn(),
      close: vi.fn(),
      persistedLastPage: null,
      persistLastPage,
    };
    window.history.replaceState(null, "", "#k=item-1");
    render(<App />);

    await waitFor(() => {
      expect(persistLastPage).toHaveBeenCalledWith({ activeView: "timeline", hash: "#k=item-1" });
    });

    fireEvent.click(screen.getByRole("button", { name: "switch-view" }));
    await waitFor(() => {
      expect(persistLastPage).toHaveBeenCalledWith({ activeView: "albums", hash: "#k=item-1" });
    });

    window.history.replaceState(null, "", "#k=item-2&v=item-2");
    window.dispatchEvent(new PopStateEvent("popstate"));
    await waitFor(() => {
      expect(persistLastPage).toHaveBeenCalledWith({ activeView: "albums", hash: "#k=item-2&v=item-2" });
    });

    window.dispatchEvent(new Event("beforeunload"));
    await waitFor(() => {
      expect(persistLastPage).toHaveBeenLastCalledWith({
        activeView: "albums",
        hash: "#k=item-2&v=item-2",
      });
    });
  });

  it("initializes and updates commit pane hash state via sp", async () => {
    window.history.replaceState(null, "", "#sp=1&k=item-1");
    render(<App />);

    expect(screen.getByRole("button", { name: "hide-commit-pane" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "hide-commit-pane" }));
    await waitFor(() => {
      expect(window.location.hash).toContain("k=item-1");
      expect(window.location.hash).not.toContain("sp=");
    });

    fireEvent.click(screen.getByRole("button", { name: "show-commit-pane" }));
    await waitFor(() => {
      expect(window.location.hash).toContain("sp=1");
      expect(window.location.hash).toContain("k=item-1");
    });
  });

  it("wipes local state when reset and resync is confirmed", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<App />);

    fireEvent.click(screen.getByRole("button", { name: "reset-and-resync" }));

    await waitFor(() => {
      expect(runtimeMock.wipeReplycantState).toHaveBeenCalledTimes(1);
    });
    confirmSpy.mockRestore();
  });

  it("does not wipe local state when reset and resync is cancelled", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<App />);

    fireEvent.click(screen.getByRole("button", { name: "reset-and-resync" }));

    await waitFor(() => {
      expect(runtimeMock.wipeReplycantState).not.toHaveBeenCalled();
    });
    confirmSpy.mockRestore();
  });
});
