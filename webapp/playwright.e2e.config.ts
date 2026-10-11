import { defineConfig, devices } from "@playwright/test";

// Runs mocked browser e2e in Chromium, the engine Electron ships with.
export default defineConfig({
  testDir: ".",
  testMatch: "src/e2e/**/*.e2e.spec.ts",
  testIgnore: ["src/e2e/readme-screenshot.spec.ts", "src/e2e/integration/**"],
  timeout: 30_000,
  reporter: [["list"]],
  use: {
    ...devices["Desktop Chrome"],
    headless: true,
    baseURL: "http://127.0.0.1:5173",
  },
  webServer: {
    command: "npm run dev",
    url: "http://127.0.0.1:5173",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
