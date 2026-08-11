import { useCallback, useEffect, useState } from "react";
import { CommitPane } from "./components/CommitPane";
import { readHashParams, writeHashParam } from "./lib/hashState";
import { CollectionPlaceholderView } from "./modules/library/CollectionPlaceholderView";
import { useLibraryRuntime } from "./modules/library/useLibraryRuntime";
import { OnboardingGate } from "./modules/onboarding/OnboardingGate";
import { useOnboardingFlow } from "./modules/onboarding/useOnboardingFlow";
import { LibraryView, TimelineView } from "./modules/timeline/TimelineView";

declare global {
  // Types the DevTools helper object so manual debugging commands stay discoverable and safe.
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

// Accepts only shipped view identifiers so corrupted storage falls back safely.
const isLibraryView = (value: string): value is LibraryView =>
  value === "timeline" || value === "albums" || value === "favorites";

// Restores desktop view selection so relaunch returns to the prior section.
const readInitialActiveView = (): LibraryView => {
  const stored = window.replycantDesktop?.persistedLastPage;
  if (!stored || !isLibraryView(stored.activeView)) return "timeline";
  return stored.activeView;
};

// Restores the commit pane affordance from hash so reload keeps shell layout.
const readInitialCommitPaneOpen = (): boolean => readHashParams().get("sp") === "1";

// Composes onboarding, runtime, and active library view modules so App can stay a thin shell.
export const App = () => {
  const [activeView, setActiveView] = useState<LibraryView>(() => readInitialActiveView());
  const [commitPaneOpen, setCommitPaneOpen] = useState(() => readInitialCommitPaneOpen());
  const onboarding = useOnboardingFlow();
  const runtime = useLibraryRuntime({
    setupMode: onboarding.setupMode,
    rehydrationKey: onboarding.rehydrationKey,
    mtlsHeaders: onboarding.mtlsHeaders,
    agePrivateKeyBase64: onboarding.identity?.agePrivateKeyBase64 ?? null,
    setSetupMode: onboarding.setSetupMode,
    setSetupError: onboarding.setSetupError,
  });

  // Registers one top-level helper object so DevTools commands stay grouped under one namespace.
  useEffect(() => {
    window.replycant = {
      wipeState: runtime.wipeReplycantState,
      syncToCommit: (commitHash: string) => runtime.handleJumpToCommit(commitHash),
    };
    return () => {
      delete window.replycant;
    };
  }, [runtime.handleJumpToCommit, runtime.wipeReplycantState]);

  // Persists desktop navigation state so restarts return to the same page
  // context even when navigation updates hash via history.replaceState.
  useEffect(() => {
    if (!window.replycantDesktop) return;
    const persistLastPage = () => {
      window.replycantDesktop?.persistLastPage({ activeView, hash: window.location.hash });
    };
    persistLastPage();
    window.addEventListener("beforeunload", persistLastPage);
    window.addEventListener("popstate", persistLastPage);
    return () => {
      window.removeEventListener("beforeunload", persistLastPage);
      window.removeEventListener("popstate", persistLastPage);
    };
  }, [activeView]);

  // Requires explicit confirmation so users do not accidentally wipe local timeline state.
  const handleResetAndResync = useCallback(async () => {
    if (
      !window.confirm(
        "This will delete all local data and resync from the server. "
          + "Your encryption key and server settings will be kept. " +
          "As long as your last commit has been pushed to the server, this is a safe operation.",
      )
    ) {
      return;
    }
    await runtime.wipeReplycantState();
  }, [runtime]);

  const commitPane = commitPaneOpen ? (
    <CommitPane
      commits={runtime.rewindCommits}
      timelineItemCount={runtime.timelineItemCount}
      syncedCommitHash={runtime.snapshot.syncedCommitHash}
      periodicSyncUserEnabled={runtime.snapshot.periodicSyncUserEnabled}
      syncIntervalMs={runtime.snapshot.syncIntervalMs}
      isOffHead={runtime.snapshot.isOffHead}
      rewindActionBusy={runtime.rewindActionBusy}
      onSelectCommit={runtime.handleJumpToCommit}
      onTogglePeriodicSync={runtime.handleTogglePeriodicSync}
      onChangeSyncInterval={runtime.handleChangeSyncInterval}
      syncing={runtime.snapshot.syncing}
      error={runtime.snapshot.error}
      lastSyncAt={runtime.snapshot.lastSyncAt}
      requiresHardResetPermission={runtime.snapshot.requiresHardResetPermission}
      cloneProgress={runtime.snapshot.cloneProgress}
      onSyncNow={runtime.handleSyncNow}
      onResetToRemote={runtime.handleResetToRemote}
      onResetAndResync={handleResetAndResync}
    />
  ) : null;

  // Keeps hash state aligned with the settings/commit panel visibility toggle.
  const handleToggleCommitPane = () => {
    setCommitPaneOpen((current) => {
      const next = !current;
      writeHashParam("sp", next ? "1" : null);
      return next;
    });
  };

  return (
    <OnboardingGate flow={onboarding} snapshot={runtime.snapshot}>
      {activeView === "timeline" ? (
        <TimelineView
          runtime={runtime}
          mtlsHeaders={onboarding.mtlsHeaders}
          activeView={activeView}
          onSelectView={setActiveView}
          commitPaneOpen={commitPaneOpen}
          onToggleCommitPane={handleToggleCommitPane}
          commitPane={commitPane}
        />
      ) : (
        <CollectionPlaceholderView
          activeView={activeView}
          onSelectView={setActiveView}
          commitPaneOpen={commitPaneOpen}
          onToggleCommitPane={handleToggleCommitPane}
          commitPane={commitPane}
          snapshot={runtime.snapshot}
        />
      )}
    </OnboardingGate>
  );
};
