import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Builds the tsnet sidecar for whichever platform electron-builder is about to
// package for.
//
// This exists as a script rather than an npm one-liner because it is the first
// native binary the desktop app ships, and the three release runners disagree
// on shell syntax, executable suffix, and how to reach the Go module root
// (which is the repository root, one level above webapp/).
const webappDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(webappDir, "..");

// GOOS/GOARCH default to the host, which is what the release matrix wants:
// each runner packages for its own platform. They stay overridable so a
// maintainer can produce a cross-built artifact by hand.
const goos = process.env.GOOS ?? "";
const goarch = process.env.GOARCH ?? "";
const targetOs = goos || process.platform;
const suffix = targetOs === "win32" || targetOs === "windows" ? ".exe" : "";

const outputDir = join(webappDir, "sidecar", "build");
mkdirSync(outputDir, { recursive: true });
const outputPath = join(outputDir, `replycant-tsnet${suffix}`);

// CGO off keeps the binary portable across the glibc versions users run, and
// -trimpath keeps absolute build paths out of a shipped artifact.
const result = spawnSync(
  "go",
  ["build", "-trimpath", "-o", outputPath, "./webapp/sidecar"],
  {
    cwd: repoRoot,
    stdio: "inherit",
    env: { ...process.env, CGO_ENABLED: "0", ...(goos && { GOOS: goos }), ...(goarch && { GOARCH: goarch }) },
  },
);

if (result.error) {
  console.error(`Failed to run go build: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
