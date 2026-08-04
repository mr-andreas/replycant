import { expect, test } from "@playwright/test";
import { createSyntheticGitRepoFixture, parseSyntheticRepoOptions } from "./gitPull.fixture";
import { PullSample, SyncPhaseTimings, summarizeByBrowser, writeBenchmarkReport } from "./report";
import { resetBrowserSyncState, runManualSync } from "./benchmarkHelpers";

const options = parseSyntheticRepoOptions();
const benchmarkIterations = Number(process.env.GIT_BENCH_ITERATIONS ?? "6");
const benchmarkSamples: PullSample[] = [];

test.describe.configure({ mode: "serial" });

// Benchmarks the cold-start initial sync (clone + full hydration + cache population) so the
// heaviest user-facing operation has a regression baseline across browsers.
test("initial sync benchmark", async ({ browserName, baseURL, page }) => {
  expect(baseURL).toBeTruthy();
  const fixture = await createSyntheticGitRepoFixture(options);
  try {
    for (let iteration = 0; iteration < benchmarkIterations; iteration += 1) {
      await resetBrowserSyncState(page);

      const measured = await runManualSync(page, fixture.apiBasePath, fixture.agePrivateKeyBase64);
      expect(measured.error).toBeNull();
      expect(measured.syncedCommitHash).toBe(fixture.baselineHead);

      benchmarkSamples.push({
        browser: browserName,
        iteration: iteration + 1,
        durationMs: measured.durationMs,
        remoteHead: fixture.baselineHead,
        phases: measured.phases,
      });
    }

    const objectCount = await fixture.getRemoteObjectCount();
    const summary = summarizeByBrowser(benchmarkSamples.filter((sample) => sample.browser === browserName));
    const reportPath = await writeBenchmarkReport({
      scenario: "initial-sync-cold-start",
      fixture: {
        baselineHead: fixture.baselineHead,
        objectCount,
        manifestCount: options.manifestCount,
        baselineCommitCount: options.baselineCommitCount,
        deviceSpaceCount: options.deviceSpaceCount,
        treeFanout: options.treeFanout,
      },
      samples: benchmarkSamples.filter((sample) => sample.browser === browserName),
      summary,
      createdAt: new Date().toISOString(),
    });
    console.log(`[initialsync-benchmark] browser=${browserName} report=${reportPath}`);
    for (const row of summary) {
      console.log(
        `[initialsync-benchmark] browser=${row.browser} n=${row.iterations} median=${row.medianMs.toFixed(2)}ms p95=${row.p95Ms.toFixed(2)}ms`,
      );
    }
    const browserSamples = benchmarkSamples.filter((s) => s.browser === browserName && s.phases);
    if (browserSamples.length > 0) {
      const phaseKeys: (keyof SyncPhaseTimings)[] = [
        "cloneMs", "pullMs", "manifestWalkMs", "normalizeMs",
        "changeSetMs", "replaceCacheMs", "cacheRefreshMs",
      ];
      for (const key of phaseKeys) {
        const values = browserSamples.map((s) => s.phases?.[key]).filter((v): v is number => v !== undefined);
        if (values.length === 0) continue;
        const sorted = [...values].sort((a, b) => a - b);
        const median = sorted[Math.floor(sorted.length / 2)];
        console.log(
          `[initialsync-benchmark]   phase=${key} median=${median.toFixed(2)}ms samples=${values.length}`,
        );
      }
    }
  } finally {
    await fixture.dispose();
  }
});
