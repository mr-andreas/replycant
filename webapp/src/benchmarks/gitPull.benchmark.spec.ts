import { expect, test } from "@playwright/test";
import { createSyntheticGitRepoFixture, parseSyntheticRepoOptions } from "./gitPull.fixture";
import { PullSample, SyncPhaseTimings, summarizeByBrowser, writeBenchmarkReport } from "./report";
import { resetBrowserSyncState, runManualSync } from "./benchmarkHelpers";

const options = parseSyntheticRepoOptions();
const benchmarkIterations = Number(process.env.GIT_BENCH_ITERATIONS ?? "6");
const benchmarkSamples: PullSample[] = [];

test.describe.configure({ mode: "serial" });

// Benchmarks a single-commit pull transition repeatedly so browser-specific latency can be compared.
test("git pull one-new-commit benchmark", async ({ browserName, baseURL, page }) => {
  expect(baseURL).toBeTruthy();
  const fixture = await createSyntheticGitRepoFixture(options);
  try {
    for (let iteration = 0; iteration < benchmarkIterations; iteration += 1) {
      await fixture.resetRemoteToBaseline();
      await resetBrowserSyncState(page);

      const baselineSync = await runManualSync(page, fixture.apiBasePath, fixture.agePrivateKeyBase64);
      expect(baselineSync.error).toBeNull();
      expect(baselineSync.syncedCommitHash).toBe(fixture.baselineHead);

      const newHead = await fixture.appendSingleCommit();
      const measured = await runManualSync(page, fixture.apiBasePath, fixture.agePrivateKeyBase64);
      expect(measured.error).toBeNull();
      expect(measured.syncedCommitHash).toBe(newHead);

      benchmarkSamples.push({
        browser: browserName,
        iteration: iteration + 1,
        durationMs: measured.durationMs,
        remoteHead: newHead,
        phases: measured.phases,
      });
    }

    const objectCount = await fixture.getRemoteObjectCount();
    const summary = summarizeByBrowser(benchmarkSamples.filter((sample) => sample.browser === browserName));
    const reportPath = await writeBenchmarkReport({
      scenario: "pull-with-single-new-commit",
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
    console.log(`[gitpull-benchmark] browser=${browserName} report=${reportPath}`);
    for (const row of summary) {
      console.log(
        `[gitpull-benchmark] browser=${row.browser} n=${row.iterations} median=${row.medianMs.toFixed(2)}ms p95=${row.p95Ms.toFixed(2)}ms`,
      );
    }
    const browserSamples = benchmarkSamples.filter((s) => s.browser === browserName && s.phases);
    if (browserSamples.length > 0) {
      const phaseKeys: (keyof SyncPhaseTimings)[] = [
        "listServerRefsMs", "cloneMs", "fetchMs", "pullMs", "manifestWalkMs", "normalizeMs",
        "changeSetMs", "incrementalChangedPathsMs", "incrementalBuildMutationMs",
        "incrementalCasApplyMs", "replaceCacheMs", "cacheRefreshMs",
      ];
      for (const key of phaseKeys) {
        const values = browserSamples.map((s) => s.phases?.[key]).filter((v): v is number => v !== undefined);
        if (values.length === 0) continue;
        const sorted = [...values].sort((a, b) => a - b);
        const median = sorted[Math.floor(sorted.length / 2)];
        console.log(
          `[gitpull-benchmark]   phase=${key} median=${median.toFixed(2)}ms samples=${values.length}`,
        );
      }
    }
  } finally {
    await fixture.dispose();
  }
});
