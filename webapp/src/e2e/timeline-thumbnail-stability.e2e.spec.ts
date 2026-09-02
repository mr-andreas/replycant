import type { Locator, Page, Route } from "@playwright/test";
import { encryptBinaryChunked } from "../modules/gitdb/testEncryption";
import { expect, test, unlockBypassIdentity } from "./fixtures";
import { seedTimelineIndexedDb } from "./timelineSeed";

// Counts visible timeline media states so resize regressions catch placeholder flicker.
const visibleMediaState = async (timeline: Locator) =>
  timeline.evaluate((node) => {
    const viewport = node.getBoundingClientRect();
    const isVisible = (element: Element): boolean => {
      const rect = element.getBoundingClientRect();
      return rect.bottom > viewport.top && rect.top < viewport.bottom;
    };
    const tiles = Array.from(node.querySelectorAll("button.image-tile")).filter(isVisible);
    const placeholders = tiles.filter((tile) => tile.querySelector(".media-placeholder")).length;
    const loadedImages = tiles.filter((tile) => {
      const image = tile.querySelector("img");
      return image instanceof HTMLImageElement && image.complete && image.naturalWidth > 0;
    }).length;
    return { tiles: tiles.length, placeholders, loadedImages };
  });

// Counts visible tile buttons that render neither a loaded image nor a placeholder label.
const visibleEmptyTileState = async (timeline: Locator) =>
  timeline.evaluate((node) => {
    const viewport = node.getBoundingClientRect();
    const isVisible = (element: Element): boolean => {
      const rect = element.getBoundingClientRect();
      return rect.bottom > viewport.top && rect.top < viewport.bottom;
    };
    const tiles = Array.from(node.querySelectorAll("button.image-tile")).filter(isVisible);
    const emptyTiles = tiles.filter((tile) => {
      if (tile.querySelector(".media-placeholder")) return false;
      const image = tile.querySelector("img");
      return !(image instanceof HTMLImageElement) || !image.complete || image.naturalWidth === 0;
    }).length;
    const failedTiles = tiles.filter((tile) => tile.textContent?.includes("Media unavailable")).length;
    const loadingTiles = tiles.filter((tile) => tile.textContent?.includes("Loading")).length;
    return { tiles: tiles.length, emptyTiles, failedTiles, loadingTiles };
  });

// Watches every animation frame so short-lived blank tiles cannot slip between test samples.
const startEmptyTileMonitor = async (timeline: Locator) =>
  timeline.evaluate((node) => {
    const win = window as typeof window & {
      __replycantEmptyTileMonitor?: { maxEmptyTiles: number; stop: boolean };
    };
    win.__replycantEmptyTileMonitor = { maxEmptyTiles: 0, stop: false };
    const countEmptyTiles = () => {
      const viewport = node.getBoundingClientRect();
      const tiles = Array.from(node.querySelectorAll("button.image-tile")).filter((tile) => {
        const rect = tile.getBoundingClientRect();
        return rect.bottom > viewport.top && rect.top < viewport.bottom;
      });
      return tiles.filter((tile) => {
        if (tile.querySelector(".media-placeholder")) return false;
        const image = tile.querySelector("img");
        return !(image instanceof HTMLImageElement) || !image.complete || image.naturalWidth === 0;
      }).length;
    };
    const tick = () => {
      const monitor = win.__replycantEmptyTileMonitor;
      if (!monitor || monitor.stop) return;
      monitor.maxEmptyTiles = Math.max(monitor.maxEmptyTiles, countEmptyTiles());
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });

// Returns the max blank visible tile count observed by the in-page frame monitor.
const stopEmptyTileMonitor = async (page: Page) =>
  page.evaluate(() => {
    const win = window as typeof window & {
      __replycantEmptyTileMonitor?: { maxEmptyTiles: number; stop: boolean };
    };
    const monitor = win.__replycantEmptyTileMonitor;
    if (!monitor) return 0;
    monitor.stop = true;
    return monitor.maxEmptyTiles;
  });

// Valid 1x1 PNG so Firefox Image.decode accepts the decrypted blob.
const MINIMAL_PNG = Uint8Array.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0xc9, 0xfe, 0x92, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82,
]);

// Serves encrypted thumbnails so AuthImage decrypt matches seeded pointer DEKs.
const routeThumbnails = async (page: Page, delayMs: () => number, requestedUrls: Set<string>) => {
  await page.route("**/api/lfs/objects/**", async (route: Route) => {
    const url = route.request().url();
    requestedUrls.add(url);
    const delay = delayMs();
    if (delay > 0) {
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
    // Unique OIDs in the URL drive cache churn; plaintext can be identical.
    const encrypted = await encryptBinaryChunked(MINIMAL_PNG);
    await route.fulfill({
      status: 200,
      contentType: "application/octet-stream",
      body: Buffer.from(encrypted),
    });
  });
};

test.describe("Timeline thumbnail stability", () => {
  test("keeps visible thumbnails rendered after preload churn and resize", async ({ page, resetState, bypassOnboarding }) => {
    void resetState;
    void bypassOnboarding;
    const requestedUrls = new Set<string>();
    let mediaDelayMs = 0;
    await routeThumbnails(page, () => mediaDelayMs, requestedUrls);
    await page.setViewportSize({ width: 1100, height: 700 });

    await page.goto("/");
    await unlockBypassIdentity(page);
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 15_000 });
    await seedTimelineIndexedDb(page, 900, { uniqueThumbnailSha: true });

    await page.reload();
    await unlockBypassIdentity(page);
    const timeline = page.locator("main.timeline");
    await expect(timeline).toBeVisible();
    await expect.poll(
      async () => (await visibleMediaState(timeline)).loadedImages,
      { timeout: 10_000, message: "initial viewport should have loaded thumbnails" },
    ).toBeGreaterThan(8);

    // Jump past the initial 25-after preload page so later unique OIDs
    // are fetched. Small down-steps stay inside that already-fetched
    // window and leave Firefox at ~37 URLs on the 6.75cm grid.
    await timeline.evaluate((node) => {
      const row = node.querySelector(".image-row");
      if (!(row instanceof HTMLElement)) throw new Error("timeline row not rendered");
      const tileHeight = row.getBoundingClientRect().height;
      const rowHeight = tileHeight + 2;
      node.scrollTop = rowHeight * 12;
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
    });

    // Unique LFS URLs must exceed the initial viewport plus one preload page.
    await expect.poll(
      async () => requestedUrls.size,
      { timeout: 10_000, message: "timeline preload should request enough unique thumbnails to churn the cache" },
    ).toBeGreaterThan(40);

    mediaDelayMs = 2_000;
    await startEmptyTileMonitor(timeline);
    await page.setViewportSize({ width: 760, height: 700 });
    await page.waitForTimeout(500);
    const maxEmptyTilesAfterResize = await stopEmptyTileMonitor(page);

    const stateAfterResize = await visibleMediaState(timeline);
    expect(stateAfterResize.tiles).toBeGreaterThan(6);
    expect(maxEmptyTilesAfterResize).toBe(0);
    expect(stateAfterResize.loadedImages).toBeGreaterThan(6);
  });

  test("does not leave empty visible tiles during small upward mouse-wheel scroll steps", async ({ page, resetState, bypassOnboarding }) => {
    void resetState;
    void bypassOnboarding;
    const requestedUrls = new Set<string>();
    let mediaDelayMs = 0;
    await routeThumbnails(page, () => mediaDelayMs, requestedUrls);
    await page.setViewportSize({ width: 800, height: 480 });

    await page.goto("/");
    await unlockBypassIdentity(page);
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 15_000 });
    await seedTimelineIndexedDb(page, 900, { uniqueThumbnailSha: true });

    await page.reload();
    await unlockBypassIdentity(page);
    const timeline = page.locator("main.timeline");
    await expect(timeline).toBeVisible();
    // 6.75cm tiles yield 3 columns at 800px, so a 480px-tall viewport holds ~6 tiles.
    await expect.poll(
      async () => (await visibleMediaState(timeline)).loadedImages,
      { timeout: 10_000, message: "initial narrow viewport should have loaded thumbnails" },
    ).toBeGreaterThan(4);

    const box = await timeline.boundingBox();
    if (!box) throw new Error("timeline bounding box not available");
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await startEmptyTileMonitor(timeline);
    for (let step = 0; step < 14; step += 1) {
      await page.mouse.wheel(0, -120);
      await page.waitForTimeout(40);
    }
    const maxEmptyTiles = await stopEmptyTileMonitor(page);

    const stateAfterScroll = await visibleMediaState(timeline);
    const emptyStateAfterScroll = await visibleEmptyTileState(timeline);
    expect(stateAfterScroll.tiles).toBeGreaterThan(4);
    expect(emptyStateAfterScroll.failedTiles).toBe(0);
    expect(emptyStateAfterScroll.loadingTiles).toBe(0);
    expect(maxEmptyTiles).toBe(0);
    expect(stateAfterScroll.loadedImages).toBeGreaterThan(4);
  });
});
