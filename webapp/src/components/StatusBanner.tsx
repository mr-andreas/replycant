interface StatusBannerProps {
  syncing: boolean;
  error: string | null;
  lastSyncAt: string | null;
  periodicSyncUserEnabled: boolean;
  syncIntervalMs: number;
  isOffHead: boolean;
  requiresHardResetPermission: boolean;
  cloneProgress: { phase: string; progress: number; loaded?: number; total?: number } | null;
  onSyncNow: () => void;
  onResetToRemote: () => void;
  onTogglePeriodicSync: (enabled: boolean) => void;
  onChangeSyncInterval: (intervalMs: number) => void;
}

// Surfaces sync health, auto-sync controls, and manual recovery
// actions in one persistent banner so the user always knows the
// current sync posture without opening a separate panel.
export const StatusBanner = ({
  syncing,
  error,
  lastSyncAt,
  periodicSyncUserEnabled,
  syncIntervalMs,
  isOffHead,
  requiresHardResetPermission,
  cloneProgress,
  onSyncNow,
  onResetToRemote,
  onTogglePeriodicSync,
  onChangeSyncInterval,
}: StatusBannerProps) => (
  <section className={`status-banner ${error ? "error" : "ok"}`}>
    <div>
      <strong>{syncing ? "Syncing..." : error ? "Sync failed" : "Ready"}</strong>
      {error ? <p>{error}</p> : <p>{lastSyncAt ? `Last sync: ${new Date(lastSyncAt).toLocaleString()}` : "No sync yet"}</p>}
    </div>
    <div className="status-banner-controls">
      <label className="status-banner-toggle">
        <input
          type="checkbox"
          checked={periodicSyncUserEnabled}
          onChange={(event) => onTogglePeriodicSync(event.target.checked)}
          disabled={isOffHead}
        />
        <span>Auto</span>
      </label>
      <select
        className="status-banner-interval"
        value={syncIntervalMs}
        onChange={(event) => onChangeSyncInterval(Number.parseInt(event.target.value, 10))}
        disabled={isOffHead || !periodicSyncUserEnabled}
      >
        <option value={2000}>2s</option>
        <option value={5000}>5s</option>
        <option value={10000}>10s</option>
        <option value={30000}>30s</option>
      </select>
    </div>
    <div className="status-banner-actions">
      {isOffHead ? (
        <p className="status-banner-off-head">Return to head to sync</p>
      ) : cloneProgress ? (
        <div className="status-banner-progress">
          <p>
            {cloneProgress.phase}:{" "}
            {cloneProgress.loaded != null && cloneProgress.total != null
              ? `${cloneProgress.loaded.toLocaleString()} / ${cloneProgress.total.toLocaleString()}`
              : `${Math.round(cloneProgress.progress * 100)}%`}
          </p>
          <progress
            value={cloneProgress.progress}
            max={1}
          />
        </div>
      ) : (
        <button type="button" onClick={onSyncNow} disabled={syncing}>
          Sync now
        </button>
      )}
      {requiresHardResetPermission ? (
        <button type="button" onClick={onResetToRemote} disabled={syncing}>
          Reset to remote
        </button>
      ) : null}
    </div>
  </section>
);
