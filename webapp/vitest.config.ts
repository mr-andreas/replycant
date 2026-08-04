import { defineConfig } from "vitest/config";

// Disables Node web storage in test workers so jsdom owns browser storage APIs.
const vitestExecArgv = process.allowedNodeEnvironmentFlags.has("--no-experimental-webstorage")
  ? ["--no-experimental-webstorage"]
  : [];

// Keeps unit test configuration isolated from the production Vite build config.
export default defineConfig({
  test: {
    execArgv: vitestExecArgv,
    environment: "jsdom",
    setupFiles: "./src/setupTests.ts",
    include: [
      "src/**/*.test.ts",
      "src/**/*.test.tsx",
      "server/**/*.test.ts",
      "electron/**/*.test.ts",
    ],
  },
});
