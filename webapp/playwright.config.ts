import { defineConfig, devices } from "@playwright/test";

// Runs git benchmarks headless in Chromium so timings match the Electron runtime.
export default defineConfig({
  testDir: ".",
  testMatch: "src/benchmarks/**/*.benchmark.spec.ts",
  timeout: 10 * 60 * 1000,
  reporter: [["list"]],
  use: {
    ...devices["Desktop Chrome"],
    headless: true,
    baseURL: "http://127.0.0.1:4173",
  },
  webServer: {
    command: "npx vite --host 127.0.0.1 --port 4173",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
