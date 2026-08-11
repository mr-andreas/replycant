import { useEffect, useState } from "react";
import type { SyncSnapshot } from "../gitdb";

// Keeps short auto-poll syncs from flashing a progress affordance in the header.
export const SYNC_PROGRESS_DELAY_MS = 2000;

// Surfaces delayed sync visibility plus phase/progress so the header bar only
// appears for long-running cycles and still tracks live cloneProgress updates.
export const useDelayedSyncProgress = (
  snapshot: SyncSnapshot | null | undefined,
): { visible: boolean; phase: string | null; progress: number | null } => {
  const syncing = snapshot?.syncing ?? false;
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (!syncing) {
      setVisible(false);
      return;
    }
    const timer = window.setTimeout(() => setVisible(true), SYNC_PROGRESS_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, [syncing]);

  return {
    visible,
    phase: snapshot?.cloneProgress?.phase ?? null,
    progress: snapshot?.cloneProgress?.progress ?? null,
  };
};
