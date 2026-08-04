import { defineConfig, devices } from "@playwright/test";

// Defines a headless cross-browser matrix so git pull benchmarks are comparable across Chrome and Firefox.
export default defineConfig({
  testDir: ".",
  testMatch: "src/benchmarks/**/*.benchmark.spec.ts",
  timeout: 10 * 60 * 1000,
  reporter: [["list"]],
  use: {
    headless: true,
    baseURL: "http://127.0.0.1:4173",
  },
  webServer: {
    command: "npx vite --host 127.0.0.1 --port 4173",
    url: "http://127.0.0.1:4173",
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
