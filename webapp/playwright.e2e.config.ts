import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "src/e2e/**/*.e2e.spec.ts",
  testIgnore: ["src/e2e/readme-screenshot.spec.ts"],
  timeout: 30_000,
  globalSetup: "./src/e2e/global-setup.ts",
  globalTeardown: "./src/e2e/global-teardown.ts",
  reporter: [["list"]],
  use: {
    headless: true,
    baseURL: "http://127.0.0.1:5173",
  },
  webServer: {
    command: "npm run dev",
    url: "http://127.0.0.1:5173",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  projects: [
    {
      name: "chrome",
      use: {
        ...devices["Desktop Chrome"],
        browserName: "chromium",
      },
    },
    {
      name: "firefox",
      use: {
        ...devices["Desktop Firefox"],
        browserName: "firefox",
      },
    },
  ],
});
