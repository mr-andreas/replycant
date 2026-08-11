import { defineConfig } from "@playwright/test";

const README_PORT = 5181;
const README_URL = `http://127.0.0.1:${README_PORT}`;

// Isolates README Electron capture from regular e2e so Docker integration setup
// and multi-browser projects do not slow marketing screenshot regeneration.
export default defineConfig({
  testDir: ".",
  testMatch: "src/e2e/readme-screenshot.spec.ts",
  timeout: 120_000,
  workers: 1,
  reporter: [["list"]],
  use: {
    headless: true,
    baseURL: README_URL,
  },
  webServer: {
    command: `cross-env VITE_PORT=${README_PORT} vite --strictPort`,
    url: README_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
