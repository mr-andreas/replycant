import type { SyncSnapshot } from "../modules/gitdb";
import { useDelayedSyncProgress } from "../modules/library/useDelayedSyncProgress";

// Accepts the live sync snapshot so the header can show delayed pull progress.
interface SyncProgressBarProps {
  snapshot: SyncSnapshot | null | undefined;
}

// Renders a thin header progress track only after sync has been continuous long
// enough that short poll cycles stay silent for users.
export const SyncProgressBar = ({ snapshot }: SyncProgressBarProps) => {
  const { visible, phase, progress } = useDelayedSyncProgress(snapshot);
  if (!visible) return null;

  const determinate = progress != null;
  const percent = determinate ? Math.round(Math.min(1, Math.max(0, progress)) * 100) : null;

  return (
    <div
      className="sync-progress"
      role="progressbar"
      aria-label={phase ?? "Syncing"}
      aria-valuemin={0}
      aria-valuemax={100}
      {...(determinate
        ? { "aria-valuenow": percent ?? 0 }
        : { "aria-valuetext": "Syncing" })}
    >
      <div
        className={`sync-progress-fill${determinate ? "" : " indeterminate"}`}
        style={determinate ? { width: `${percent}%` } : undefined}
      />
    </div>
  );
};
