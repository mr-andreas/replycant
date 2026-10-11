import { defineConfig } from "@playwright/test";
import { API_URL, RENDERER_PORT, RENDERER_URL } from "./src/e2e/integration/desktop";

// Runs the real desktop app against the integration container, so pairing,
// the tailnet sidecar, and the desktop git proxy are exercised end to end.
// Kept apart from the mocked browser e2e because it needs Docker, a built
// Electron runtime and sidecar, and one shared container driven serially.
export default defineConfig({
  testDir: ".",
  testMatch: "src/e2e/integration/**/*.e2e.spec.ts",
  timeout: 300_000,
  workers: 1,
  globalSetup: "./src/e2e/global-setup.ts",
  globalTeardown: "./src/e2e/global-teardown.ts",
  reporter: [["list"]],
  webServer: {
    command: `cross-env VITE_PORT=${RENDERER_PORT} REPLYCANT_DESKTOP_API=${API_URL} vite --strictPort`,
    url: RENDERER_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
