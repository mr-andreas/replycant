import { expect, test, _electron as electron } from "@playwright/test";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setupOnboardingBypass, unlockBypassIdentity } from "./fixtures";
import {
  buildEncryptedDemoByOid,
  listDemoMediaPaths,
  routeDemoThumbnails,
} from "./readmeDemoMedia";
import { previewTakenAtSchedule, seedTimelineIndexedDb } from "./timelineSeed";

const RENDERER_URL = "http://127.0.0.1:5181";
const OUTPUT_PATH = resolve(process.cwd(), "../docs/static/img/readme/desktop-timeline.png");
const ELECTRON_MAIN = resolve(process.cwd(), "dist-electron/dev-main.js");

// Captures the Electron timeline window with seeded demo photos for README releases.
test("capture electron timeline for README", async () => {
  const demoPaths = listDemoMediaPaths();
  expect(demoPaths.length).toBeGreaterThanOrEqual(8);
  // Dense, varied months so the rail looks like a lived-in library (~4.5 years).
  const seedOptions = {
    uniqueThumbnailSha: true,
    monthCount: 54,
    itemsPerMonth: { min: 22, max: 58 },
  } as const;
  const itemCount = previewTakenAtSchedule(0, seedOptions).length;
  const encryptedByOid = await buildEncryptedDemoByOid(demoPaths, itemCount);

  const userDataDir = mkdtempSync(join(tmpdir(), "replycant-readme-ss-"));
  const electronApp = await electron.launch({
    // Force 1x device pixels so README captures stay near CSS window size.
    args: [
      ELECTRON_MAIN,
      `--user-data-dir=${userDataDir}`,
      "--force-device-scale-factor=1",
    ],
    env: {
      ...process.env,
      ELECTRON_RENDERER_URL: RENDERER_URL,
      REPLYCANT_SCREENSHOT_OPAQUE: "1",
    },
  });

  try {
    const page = await electronApp.firstWindow();
    await routeDemoThumbnails(page, encryptedByOid);
    await setupOnboardingBypass(page);

    await page.goto(`${RENDERER_URL}/`);
    await unlockBypassIdentity(page);
    // Library runtime must open IndexedDB stores before seeding can write manifests.
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 30_000 });
    await seedTimelineIndexedDb(page, itemCount, seedOptions);
    await page.reload();
    await unlockBypassIdentity(page);

    const timeline = page.locator("main.timeline");
    await expect(timeline).toBeVisible({ timeout: 30_000 });
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant");
    // Reveal the month rail after the shell is stable so the README shot shows timeline chrome.
    const monthToggle = page.getByRole("button", { name: "Show months" });
    if (await monthToggle.isVisible()) {
      await monthToggle.click();
    }
    const monthSidebar = page.locator(".month-sidebar");
    await expect(monthSidebar).toBeVisible({ timeout: 15_000 });
    const monthButtons = monthSidebar.locator(".month-sidebar-month");
    // Enough months that the rail overflows the viewport height.
    await expect
      .poll(async () => monthButtons.count(), {
        timeout: 10_000,
        message: "expected a dense month sidebar for the README capture",
      })
      .toBeGreaterThan(48);
    // Jump to a middle month so the rail is packed above and below the active row
    // instead of sitting at the newest end with empty space underneath.
    const monthCount = await monthButtons.count();
    await monthButtons.nth(Math.floor(monthCount / 2)).click();
    await expect
      .poll(
        async () =>
          monthSidebar.evaluate((node) => {
            const active = node.querySelector(".month-sidebar-month.active");
            if (!(active instanceof HTMLElement)) return false;
            const sidebarRect = node.getBoundingClientRect();
            const activeRect = active.getBoundingClientRect();
            const hasContentAbove = node.scrollTop > 8;
            const hasContentBelow =
              node.scrollTop + node.clientHeight < node.scrollHeight - 8;
            const activeVisible =
              activeRect.top >= sidebarRect.top - 1
              && activeRect.bottom <= sidebarRect.bottom + 1;
            return hasContentAbove && hasContentBelow && activeVisible;
          }),
        { timeout: 10_000, message: "expected month rail filled around the active month" },
      )
      .toBe(true);

    // Wait until real JPEG thumbs decode so the README shot is not a placeholder grid.
    await expect
      .poll(
        async () =>
          timeline.evaluate((node) => {
            const images = Array.from(node.querySelectorAll("img"));
            return images.filter(
              (image) =>
                image instanceof HTMLImageElement
                && image.complete
                && image.naturalWidth > 50,
            ).length;
          }),
        { timeout: 45_000, message: "expected loaded demo thumbnails in timeline" },
      )
      .toBeGreaterThan(6);

    // Settle layout after images paint so the capture matches a stable desktop frame.
    await page.evaluate(
      () =>
        new Promise<void>((resolveFrame) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolveFrame()));
        }),
    );

    mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
    // CSS pixels keep the README asset sharp enough without a 2x retina multi-MB PNG.
    await page.screenshot({ path: OUTPUT_PATH, type: "png", scale: "css" });
  } finally {
    await electronApp.close();
  }
});
