// Defines the storage key for restoring desktop navigation context after relaunch.
export const LAST_PAGE_STORAGE_KEY = "replycant.lastPage";

// Captures the minimal navigation snapshot needed to restore desktop sessions.
export interface LastPageState {
  activeView: string;
  hash: string;
}

// Validates persisted state shape so bad payloads cannot break app boot.
const isLastPageState = (value: unknown): value is LastPageState => {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate.activeView === "string" && typeof candidate.hash === "string";
};

// Loads persisted page context so desktop startup can restore prior navigation.
export const readLastPage = (): LastPageState | null => {
  const raw = localStorage.getItem(LAST_PAGE_STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    return isLastPageState(parsed) ? parsed : null;
  } catch {
    return null;
  }
};

// Saves page context so desktop relaunch returns users to their prior location.
export const writeLastPage = (state: LastPageState): void => {
  localStorage.setItem(LAST_PAGE_STORAGE_KEY, JSON.stringify(state));
};
