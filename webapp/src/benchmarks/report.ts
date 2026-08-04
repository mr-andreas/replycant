import path from "node:path";
import { promises as fs } from "node:fs";

// Captures per-phase timing within a single sync pass so regressions are attributable to a specific stage.
export interface SyncPhaseTimings {
  listServerRefsMs?: number;
  cloneMs?: number;
  fetchMs?: number;
  pullMs?: number;
  manifestWalkMs?: number;
  normalizeMs?: number;
  changeSetMs?: number;
  incrementalChangedPathsMs?: number;
  incrementalBuildMutationMs?: number;
  incrementalCasApplyMs?: number;
  replaceCacheMs?: number;
  cacheRefreshMs?: number;
}

export interface PullSample {
  browser: string;
  iteration: number;
  durationMs: number;
  remoteHead: string;
  phases?: SyncPhaseTimings;
  manifestsPerSecond?: number;
}

export interface PullBenchmarkResult {
  scenario: string;
  fixture: {
    baselineHead: string;
    objectCount: number;
    manifestCount: number;
    baselineCommitCount: number;
    deviceSpaceCount: number;
    treeFanout: number;
  };
  samples: PullSample[];
  summary: {
    browser: string;
    iterations: number;
    minMs: number;
    maxMs: number;
    medianMs: number;
    p95Ms: number;
    meanMs: number;
  }[];
  createdAt: string;
}

// Computes quantiles from sorted latency samples so browser comparisons stay consistent.
const quantile = (sorted: number[], percentile: number): number => {
  if (sorted.length === 0) return 0;
  const position = Math.min(sorted.length - 1, Math.max(0, Math.ceil((percentile / 100) * sorted.length) - 1));
  return sorted[position];
};

// Summarizes per-browser timing distributions so regressions are visible beyond a single average.
export const summarizeByBrowser = (samples: PullSample[]): PullBenchmarkResult["summary"] => {
  const grouped = new Map<string, number[]>();
  for (const sample of samples) {
    const list = grouped.get(sample.browser) ?? [];
    list.push(sample.durationMs);
    grouped.set(sample.browser, list);
  }
  return [...grouped.entries()].map(([browser, durations]) => {
    const sorted = [...durations].sort((a, b) => a - b);
    const sum = sorted.reduce((acc, value) => acc + value, 0);
    return {
      browser,
      iterations: sorted.length,
      minMs: sorted[0] ?? 0,
      maxMs: sorted.at(-1) ?? 0,
      medianMs: quantile(sorted, 50),
      p95Ms: quantile(sorted, 95),
      meanMs: sorted.length > 0 ? sum / sorted.length : 0,
    };
  });
};

// Persists benchmark artifacts so pull latency trends can be compared across runs.
export const writeBenchmarkReport = async (result: PullBenchmarkResult): Promise<string> => {
  const outputDir = path.join(process.cwd(), "bench-results");
  await fs.mkdir(outputDir, { recursive: true });
  const browserLabel = [...new Set(result.samples.map((sample) => sample.browser))].sort().join("+") || "none";
  const scenarioLabel = result.scenario.replace(/[^a-z0-9-]+/gi, "-").replace(/^-+|-+$/g, "").toLowerCase() || "benchmark";
  const filename = `${scenarioLabel}-${browserLabel}-${Date.now()}.json`;
  const outputPath = path.join(outputDir, filename);
  await fs.writeFile(outputPath, JSON.stringify(result, null, 2), "utf8");
  return outputPath;
};
