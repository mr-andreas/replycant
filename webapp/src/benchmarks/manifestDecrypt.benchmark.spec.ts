import { expect, test } from "@playwright/test";
import { PullSample, summarizeByBrowser, writeBenchmarkReport } from "./report";

const benchmarkIterations = Number(process.env.GIT_BENCH_ITERATIONS ?? "6");
const manifestsPerIteration = Number(process.env.GIT_BENCH_MANIFEST_COUNT ?? "1200");
const benchmarkSamples: PullSample[] = [];

// Keeps benchmark execution serial so browser runs do not overlap and skew throughput numbers.
test.describe.configure({ mode: "serial" });

// Measures encrypted-manifest decryption throughput by invoking SyncEngine's manifest decode entrypoint used by git sync reads.
test("manifest decrypt throughput benchmark", async ({ browserName, baseURL, page }) => {
  expect(baseURL).toBeTruthy();

  for (let iteration = 0; iteration < benchmarkIterations; iteration += 1) {
    await page.goto("/");
    const measured = await page.evaluate(async ({ iterationManifestCount }) => {
      // Generates realistic encrypted manifest YAML payloads so decode benchmark exercises the real repo wrapper format.
      const buildEncryptedManifestBlob = async (plaintext: string, keyRaw: Uint8Array): Promise<Uint8Array> => {
        const encoder = new TextEncoder();
        const nonce = crypto.getRandomValues(new Uint8Array(12));
        const key = await crypto.subtle.importKey("raw", keyRaw, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
        const ciphertextWithTag = await crypto.subtle.encrypt(
          { name: "AES-GCM", iv: nonce },
          key,
          encoder.encode(plaintext),
        );
        const body = new Uint8Array(nonce.length + ciphertextWithTag.byteLength);
        body.set(nonce, 0);
        body.set(new Uint8Array(ciphertextWithTag), nonce.length);
        const header = encoder.encode("REPLYCANT-ENC-V1\nkek-epoch: 1\n---\n");
        const out = new Uint8Array(header.length + body.length);
        out.set(header, 0);
        out.set(body, header.length);
        return out;
      };

      const { SyncEngine } = await import("/src/modules/gitdb/syncEngine.ts");
      const { importAes256Key } = await import("/src/lib/gitdb/encryption.ts");
      const kekRaw = crypto.getRandomValues(new Uint8Array(32));
      const kek = await importAes256Key(kekRaw);

      const engine = new SyncEngine(
        {} as never,
        () => undefined,
        () => null,
        () => "bench-age-private-key",
      );
      const engineAny = engine as unknown as {
        decodeManifestBlobToYaml: (commitHash: string, blob: Uint8Array) => Promise<string>;
        loadKekEpoch: (commitHash: string, epoch: number) => Promise<CryptoKey>;
      };
      engineAny.loadKekEpoch = async () => kek;

      const blobs: Uint8Array[] = [];
      blobs.length = 0;
      for (let i = 0; i < iterationManifestCount; i += 1) {
        const yaml = [
          "apiVersion: media.replycant.com/v1alpha1",
          "kind: Original",
          "metadata:",
          `  name: bench-${i}`,
          "  deviceSpace: bench-device",
          "spec:",
          `  id: bench-${i}`,
          `  sha256: ${String(i).padStart(64, "0")}`,
          `  path: /bench/IMG_${i}.HEIC`,
          "  filesize: 1048576",
          "  mediaType: photo",
          "  mimeType: image/heic",
          "  width: 4032",
          "  height: 3024",
          "status: {}",
          "",
        ].join("\n");
        blobs.push(await buildEncryptedManifestBlob(yaml, kekRaw));
      }

      const started = performance.now();
      for (const blob of blobs) {
        const decoded = await engineAny.decodeManifestBlobToYaml("bench-commit", blob);
        if (!decoded.startsWith("apiVersion:")) {
          throw new Error("Decoded manifest does not look like YAML.");
        }
      }
      const durationMs = performance.now() - started;
      const manifestsPerSecond = iterationManifestCount / (durationMs / 1000);
      return { durationMs, manifestCount: iterationManifestCount, manifestsPerSecond };
    }, { iterationManifestCount: manifestsPerIteration });

    benchmarkSamples.push({
      browser: browserName,
      iteration: iteration + 1,
      durationMs: measured.durationMs,
      remoteHead: "manifest-decrypt-benchmark",
      phases: {},
      manifestsPerSecond: measured.manifestsPerSecond,
    });
  }

  const browserSamples = benchmarkSamples.filter((sample) => sample.browser === browserName);
  const summary = summarizeByBrowser(browserSamples);
  const throughputValues = browserSamples
    .map((sample) => sample.manifestsPerSecond)
    .filter((value): value is number => value !== undefined);
  const meanThroughput = throughputValues.length > 0
    ? throughputValues.reduce((sum, value) => sum + value, 0) / throughputValues.length
    : 0;

  const reportPath = await writeBenchmarkReport({
    scenario: "manifest-decrypt-throughput",
    fixture: {
      baselineHead: "manifest-decrypt-benchmark",
      objectCount: manifestsPerIteration,
      manifestCount: manifestsPerIteration,
      baselineCommitCount: 1,
      deviceSpaceCount: 1,
      treeFanout: 1,
    },
    samples: browserSamples,
    summary,
    createdAt: new Date().toISOString(),
  });

  console.log(
    `[manifestdecrypt-benchmark] browser=${browserName} n=${browserSamples.length} mean-throughput=${meanThroughput.toFixed(2)} manifests/s report=${reportPath}`,
  );
  for (const sample of browserSamples) {
    console.log(
      `[manifestdecrypt-benchmark] browser=${sample.browser} iteration=${sample.iteration} duration=${sample.durationMs.toFixed(2)}ms throughput=${(sample.manifestsPerSecond ?? 0).toFixed(2)} manifests/s`,
    );
  }
});
