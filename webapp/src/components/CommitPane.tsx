import { memo } from "react";
import { SyncCommitSummary } from "../modules/gitdb";
import { StatusBanner } from "./StatusBanner";

// Combines commit rewind controls with sync health status in an inline
// sidebar so both stay visible alongside the main content area.
interface CommitPaneProps {
  commits: SyncCommitSummary[];
  timelineItemCount: number;
  syncedCommitHash: string | null;
  periodicSyncUserEnabled: boolean;
  syncIntervalMs: number;
  isOffHead: boolean;
  rewindActionBusy: "rewind" | "forward" | null;
  onSelectCommit: (commitHash: string, options?: { isHead: boolean }) => void;
  onTogglePeriodicSync: (enabled: boolean) => void;
  onChangeSyncInterval: (intervalMs: number) => void;
  syncing: boolean;
  error: string | null;
  lastSyncAt: string | null;
  requiresHardResetPermission: boolean;
  cloneProgress: {
    phase: string;
    progress: number;
    loaded?: number;
    total?: number;
  } | null;
  onSyncNow: () => void;
  onResetToRemote: () => void;
  onResetAndResync: () => void;
}

// Inline right-side pane (like the month sidebar) that surfaces
// sync health and rewind commit history from any view.
export const CommitPane = memo(({
  commits,
  timelineItemCount,
  syncedCommitHash,
  periodicSyncUserEnabled,
  syncIntervalMs,
  isOffHead,
  rewindActionBusy,
  onSelectCommit,
  onTogglePeriodicSync,
  onChangeSyncInterval,
  syncing,
  error,
  lastSyncAt,
  requiresHardResetPermission,
  cloneProgress,
  onSyncNow,
  onResetToRemote,
  onResetAndResync,
}: CommitPaneProps) => {
  return (
    <aside className="commit-pane" aria-label="Commit history">
      <h2>Sync &amp; commits</h2>
      <StatusBanner
        syncing={syncing}
        error={error}
        lastSyncAt={lastSyncAt}
        periodicSyncUserEnabled={periodicSyncUserEnabled}
        syncIntervalMs={syncIntervalMs}
        isOffHead={isOffHead}
        requiresHardResetPermission={requiresHardResetPermission}
        cloneProgress={cloneProgress}
        onSyncNow={onSyncNow}
        onResetToRemote={onResetToRemote}
        onTogglePeriodicSync={onTogglePeriodicSync}
        onChangeSyncInterval={onChangeSyncInterval}
      />
      <p className="commit-pane-count">{timelineItemCount.toLocaleString()} media in timeline</p>
      <div className="commit-list" aria-label="Recent commits">
        {commits.length === 0 ? (
          <p>No local commits yet</p>
        ) : (
          commits.map((commit, index) => {
            const isLatestHead = index === 0;
            const isActive = syncedCommitHash === commit.hash;
            return (
              <button
                key={commit.hash}
                type="button"
                className={`commit-item${isActive ? " active" : ""}`}
                aria-label={`${commit.hash.slice(0, 10)}${isLatestHead ? " (head)" : ""} ${commit.message}`}
                onClick={() => onSelectCommit(commit.hash, { isHead: isLatestHead })}
                disabled={rewindActionBusy !== null}
                title={commit.hash}
              >
                <span className="commit-item-message">{commit.message}</span>
                <span className="commit-item-hash">{commit.hash.slice(0, 10)}{isLatestHead ? " (head)" : ""}</span>
              </button>
            );
          })
        )}
      </div>
      <p className="commit-pane-section-label">Data Management</p>
      <button type="button" className="commit-pane-destructive-action" onClick={onResetAndResync}>
        Reset &amp; Resync
      </button>
    </aside>
  );
});

CommitPane.displayName = "CommitPane";
