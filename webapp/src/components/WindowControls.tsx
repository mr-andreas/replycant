// Renders custom minimize/maximize/close controls when running inside Electron.
// Returns null in a plain browser so the webapp layout is unchanged.
export const WindowControls = () => {
  const desktop = window.replycantDesktop;
  if (!desktop) return null;

  return (
    <div className="window-controls">
      <button type="button" aria-label="Minimize" onClick={() => desktop.minimize()}>
        <svg width="12" height="12" viewBox="0 0 12 12">
          <rect x="1" y="5.5" width="10" height="1" fill="currentColor" />
        </svg>
      </button>
      <button type="button" aria-label="Maximize" onClick={() => desktop.maximize()}>
        <svg width="12" height="12" viewBox="0 0 12 12">
          <rect x="1.5" y="1.5" width="9" height="9" rx="1" fill="none" stroke="currentColor" strokeWidth="1.2" />
        </svg>
      </button>
      <button type="button" className="window-control-close" aria-label="Close" onClick={() => desktop.close()}>
        <svg width="12" height="12" viewBox="0 0 12 12">
          <path d="M2.5 2.5L9.5 9.5M9.5 2.5L2.5 9.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
};
