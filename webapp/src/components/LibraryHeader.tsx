import logoUrl from "../assets/logo.png";
import type { SyncSnapshot } from "../modules/gitdb";
import { SyncProgressBar } from "./SyncProgressBar";
import { WindowControls } from "./WindowControls";

// Defines shared shell controls so all library views keep one consistent header.
interface LibraryHeaderProps {
  activeView: "timeline" | "albums" | "favorites";
  onSelectView: (view: "timeline" | "albums" | "favorites") => void;
  commitPaneOpen: boolean;
  onToggleCommitPane: () => void;
  showMonthToggle?: boolean;
  showMonthSidebar?: boolean;
  onToggleMonthSidebar?: () => void;
  syncSnapshot?: SyncSnapshot | null;
}

// Renders one reusable top bar for timeline and placeholder library views.
export const LibraryHeader = ({
  commitPaneOpen,
  onToggleCommitPane,
  showMonthToggle = false,
  showMonthSidebar = false,
  onToggleMonthSidebar,
  syncSnapshot = null,
}: LibraryHeaderProps) => (
  <>
    <header className="top-bar">
      <div className="brand">
        <img src={logoUrl} alt="" aria-hidden="true" className="brand-logo" />
        <span className="brand-wordmark">Replycant</span>
      </div>
      {/* Timeline/Albums/Favorites switcher is hidden until those views ship. */}
      <div className="header-actions">
        {showMonthToggle ? (
          <button
            type="button"
            className={`top-icon-button${showMonthSidebar ? " active" : ""}`}
            onClick={onToggleMonthSidebar}
            aria-label={showMonthSidebar ? "Hide months" : "Show months"}
            title={showMonthSidebar ? "Hide months" : "Show months"}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <rect x="3" y="4" width="18" height="17" rx="2" />
              <path d="M3 9h18M8 2v4M16 2v4" />
            </svg>
          </button>
        ) : null}
        <button
          type="button"
          className={`top-icon-button${commitPaneOpen ? " active" : ""}`}
          onClick={onToggleCommitPane}
          aria-label={commitPaneOpen ? "Hide settings and commits" : "Show settings and commits"}
          title={commitPaneOpen ? "Hide settings and commits" : "Show settings and commits"}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <circle cx="12" cy="12" r="3.2" />
            <path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z" />
          </svg>
        </button>
        <WindowControls />
      </div>
      <SyncProgressBar snapshot={syncSnapshot} />
    </header>
    {syncSnapshot?.unrecoverableError ? (
      <div className="database-version-banner" role="alert">
        {syncSnapshot.unrecoverableError}
      </div>
    ) : null}
  </>
);
