export interface RuntimeConfig {
  gitBranch: string;
  syncIntervalMs: number;
  apiBasePath: string;
  viewerPreloadAfterCount: number;
  viewerPreloadBeforeCount: number;
  timelinePreloadAfterCount: number;
  timelinePreloadBeforeCount: number;
}

// Defines localStorage key used to persist browser-owned setup discovery data across reloads.
export const SETUP_CONFIG_STORAGE_KEY = "replycant.setup.config";

// Centralizes browser runtime defaults so sync and media layers stay aligned.
export const runtimeConfig: RuntimeConfig = {
  gitBranch: "main",
  syncIntervalMs: 2_000,
  apiBasePath: "/api",
  viewerPreloadAfterCount: 2,
  viewerPreloadBeforeCount: 2,
  timelinePreloadAfterCount: 25,
  timelinePreloadBeforeCount: 25,
};
