import { ReactNode } from "react";
import { LibraryHeader } from "../../components/LibraryHeader";
import type { SyncSnapshot } from "../gitdb";
import { LibraryView } from "../timeline/TimelineView";

// Defines placeholder view dependencies so future modules can reuse shell-level controls consistently.
interface CollectionPlaceholderViewProps {
  activeView: LibraryView;
  onSelectView: (view: LibraryView) => void;
  commitPaneOpen: boolean;
  onToggleCommitPane: () => void;
  commitPane: ReactNode;
  snapshot: SyncSnapshot;
}

// Shows scaffold screens for upcoming library modules while preserving global navigation.
export const CollectionPlaceholderView = ({
  activeView,
  onSelectView,
  commitPaneOpen,
  onToggleCommitPane,
  commitPane,
  snapshot,
}: CollectionPlaceholderViewProps) => (
  <div className="app-shell">
    <div className="app-main">
      <LibraryHeader
        activeView={activeView}
        onSelectView={onSelectView}
        commitPaneOpen={commitPaneOpen}
        onToggleCommitPane={onToggleCommitPane}
        syncSnapshot={snapshot}
      />
      <div className="timeline-container">
        <div className="placeholder-content">
          <p className="empty-state">
            {activeView === "albums" ? "Albums view is coming next." : "Favorites view is coming next."}
          </p>
        </div>
        {commitPane}
      </div>
    </div>
  </div>
);
