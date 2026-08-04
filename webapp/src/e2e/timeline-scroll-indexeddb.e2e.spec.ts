import type { Locator, Page } from "@playwright/test";
import { expect, test, unlockBypassIdentity } from "./fixtures";
import { seedTimelineIndexedDb } from "./timelineSeed";

const visibleTileCounts = async (timeline: Locator) =>
  timeline.evaluate((node) => {
    const viewport = node.getBoundingClientRect();
    const isVisible = (element: Element): boolean => {
      const rect = element.getBoundingClientRect();
      return rect.bottom > viewport.top && rect.top < viewport.bottom;
    };
    const skeletonVisible = Array.from(node.querySelectorAll("div.image-tile.skeleton")).filter(isVisible).length;
    const realVisible = Array.from(node.querySelectorAll("button.image-tile")).filter(isVisible).length;
    return { skeletonVisible, realVisible };
  });

// Reproduces the scrollbar-drag race where the first random seek empties the loaded window,
// then the user drags farther before that seek result is committed. The final scroll position
// can land outside the 100-item seek page but inside the 300-item "do not seek again" threshold,
// leaving only skeleton tiles until another scroll event nudges edge loading.
const delayTimelineRandomSeeks = async (page: Page, delayMs: number) => {
  await page.addInitScript((ms) => {
    const OriginalWorker = window.Worker;
    const DelayedWorker = function (this: Worker, scriptURL: string | URL, options?: WorkerOptions) {
      const worker = new OriginalWorker(scriptURL, options);
      const delayedCallIds = new Set<number>();
      const postMessage = worker.postMessage.bind(worker);

      worker.addEventListener(
        "message",
        (event) => {
          const message = event.data as { type?: string; callId?: number };
          if (message.type !== "rpc-result" || typeof message.callId !== "number" || !delayedCallIds.has(message.callId)) {
            return;
          }
          event.stopImmediatePropagation();
          delayedCallIds.delete(message.callId);
          window.setTimeout(() => worker.dispatchEvent(new MessageEvent("message", { data: message })), ms);
        },
        true,
      );

      worker.postMessage = (message: unknown, transfer?: Transferable[] | StructuredSerializeOptions) => {
        const rpc = message as {
          type?: string;
          method?: string;
          callId?: number;
          args?: unknown[];
        };
        const request = rpc.args?.[1] as {
          type?: string;
          indexName?: string;
          direction?: string;
          skip?: number;
          limit?: number;
        } | undefined;
        if (
          rpc.type === "rpc"
          && rpc.method === "query"
          && typeof rpc.callId === "number"
          && request?.type === "cursor"
          && request.indexName === "byTakenAt"
          && request.direction === "next"
          && typeof request.skip === "number"
          && request.limit === 100
        ) {
          delayedCallIds.add(rpc.callId);
        }
        if (transfer === undefined) {
          postMessage(message);
          return;
        }
        postMessage(message, transfer as Transferable[]);
      };

      return worker;
    };
    DelayedWorker.prototype = OriginalWorker.prototype;
    window.Worker = DelayedWorker as unknown as typeof Worker;
  }, delayMs);
};

const waitForAppDebug = (page: Page, eventName: string) =>
  new Promise<void>((resolve) => {
    const handler = (message: { text: () => string }) => {
      if (!message.text().includes("[replycant-app]") || !message.text().includes(eventName)) return;
      page.off("console", handler);
      resolve();
    };
    page.on("console", handler);
  });

test.describe("Timeline large scroll (seeded IndexedDB)", () => {
  test("loads tiles at final scrollbar position without extra scroll", async ({ page, resetState, bypassOnboarding }) => {
    void resetState;
    void bypassOnboarding;
    await delayTimelineRandomSeeks(page, 800);

    await page.goto("/");
    await unlockBypassIdentity(page);
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 15_000 });
    await seedTimelineIndexedDb(page, 2000);

    await page.reload();
    await unlockBypassIdentity(page);
    const timeline = page.locator("main.timeline");
    await expect(timeline).toBeVisible();
    await expect(page.locator("main.timeline button.image-tile").first()).toBeVisible({ timeout: 10_000 });

    const seekComplete = waitForAppDebug(page, "load-fresh-region-at-index-complete");
    await timeline.evaluate(async (node) => {
      const row = node.querySelector(".image-row");
      if (!(row instanceof HTMLElement)) throw new Error("timeline row not rendered");
      const tileHeight = row.getBoundingClientRect().height;
      const columnCount = Math.max(1, getComputedStyle(row).gridTemplateColumns.split(" ").filter(Boolean).length);
      const rowHeight = tileHeight + 2;
      const topForIndex = (index: number) => Math.floor(index / columnCount) * rowHeight;
      const firstSeekIndex = 300;
      const finalIndex = firstSeekIndex + 200;

      // The first scroll triggers seekToIndex() and clears loadedItems. The second scroll mimics
      // continuing to drag the native scrollbar while that seek is still in flight.
      node.scrollTop = topForIndex(firstSeekIndex);
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      node.scrollTop = topForIndex(finalIndex);
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await seekComplete;

    await expect.poll(
      async () => (await visibleTileCounts(timeline)).realVisible,
      {
        timeout: 6_000,
        message: "final viewport should contain loaded button.image-tile rows after long drag",
      },
    ).toBeGreaterThan(0);

    const counts = await visibleTileCounts(timeline);
    expect(counts.realVisible).toBeGreaterThan(0);
  });
});
