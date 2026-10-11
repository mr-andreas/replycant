import { memo, useState, type ReactNode } from "react";
import { SyncCommitSummary } from "../modules/gitdb";
import { StatusBanner } from "./StatusBanner";
import { TailnetStatusPanel, useTailnetStatus } from "./TailnetStatusPanel";

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
  unrecoverableError?: string | null;
  onSyncNow: () => void;
  onResetToRemote: () => void;
  onResetAndResync: () => void;
}

type SettingsSectionId = "sync" | "commits" | "connectivity" | "data";

interface AccordionSectionProps {
  id: SettingsSectionId;
  title: string;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
}

// One settings group. The body stays mounted while collapsed so the
// header's aria-controls always points at a real element, and so a long
// section can scroll inside itself instead of growing the pane.
const AccordionSection = ({ id, title, open, onToggle, children }: AccordionSectionProps) => {
  const bodyId = `settings-section-${id}`;
  return (
    <section className={`settings-section${open ? " open" : ""}`}>
      <button
        type="button"
        className="settings-section-header"
        aria-expanded={open}
        aria-controls={bodyId}
        onClick={onToggle}
      >
        {title}
        <span className="settings-section-chevron" aria-hidden="true" />
      </button>
      <div id={bodyId} role="region" aria-label={title} hidden={!open} className="settings-section-body">
        {children}
      </div>
    </section>
  );
};

// Inline right-side pane that groups sync, commits, connectivity, and
// data management so a long section scrolls without hiding the others.
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
  unrecoverableError = null,
  onSyncNow,
  onResetToRemote,
  onResetAndResync,
}: CommitPaneProps) => {
  const [openSection, setOpenSection] = useState<SettingsSectionId | null>("sync");
  const tailnetStatus = useTailnetStatus();

  // One open section at a time, so the collapsed headers stay on screen
  // while the open section fills the rest of the pane.
  const toggleSection = (id: SettingsSectionId) => {
    setOpenSection((current) => (current === id ? null : id));
  };

  return (
    <aside className="commit-pane" aria-label="Commit history">
      <h2>Settings</h2>
      <div className="settings-accordion">
        <AccordionSection
          id="sync"
          title="Sync"
          open={openSection === "sync"}
          onToggle={() => toggleSection("sync")}
        >
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
        </AccordionSection>
        <AccordionSection
          id="commits"
          title="Commits"
          open={openSection === "commits"}
          onToggle={() => toggleSection("commits")}
        >
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
        </AccordionSection>
        {tailnetStatus ? (
          <AccordionSection
            id="connectivity"
            title="Connectivity"
            open={openSection === "connectivity"}
            onToggle={() => toggleSection("connectivity")}
          >
            <TailnetStatusPanel status={tailnetStatus} />
          </AccordionSection>
        ) : null}
        {unrecoverableError ? null : (
          <AccordionSection
            id="data"
            title="Data management"
            open={openSection === "data"}
            onToggle={() => toggleSection("data")}
          >
            <button type="button" className="commit-pane-destructive-action" onClick={onResetAndResync}>
              Reset &amp; Resync
            </button>
          </AccordionSection>
        )}
      </div>
    </aside>
  );
});

CommitPane.displayName = "CommitPane";
