import { test, expect, unlockBypassIdentity } from "./fixtures";

test.describe("App shell", () => {
  test.beforeEach(async ({ page, bypassOnboarding }) => {
    void bypassOnboarding;
    await page.goto("/");
    await unlockBypassIdentity(page);
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 15_000 });
  });

  test("loads with the timeline selected", async ({ page }) => {
    await expect(page.locator(".timeline-container")).toBeVisible();
    await expect(page.getByRole("tab", { name: "Timeline" })).toHaveAttribute("aria-selected", "true");
    await expect(page.getByRole("tab", { name: "Map" })).toHaveAttribute("aria-selected", "false");
    await expect(page.getByText("No media yet.")).toBeVisible();
  });

  test("opens the map from the switcher", async ({ page }) => {
    await page.getByRole("tab", { name: "Map" }).click();
    await expect(page.getByRole("tab", { name: "Map" })).toHaveAttribute("aria-selected", "true");
    await expect(page.getByText("Albums view is coming next.")).toHaveCount(0);
    await expect(page.getByText("Favorites view is coming next.")).toHaveCount(0);
    await expect(page.getByText(/No photos with location|Couldn't load the map|Loading the map/)).toBeVisible();
  });

  test("commit pane toggles open and closed", async ({ page }) => {
    await page.getByRole("button", { name: "Show settings and commits" }).click();
    await expect(page.locator("aside[aria-label='Commit history']")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();

    await page.getByRole("button", { name: "Hide settings and commits" }).click();
    await expect(page.locator("aside[aria-label='Commit history']")).toHaveCount(0);
  });

  test("month sidebar toggle switches button label", async ({ page }) => {
    await expect(page.getByRole("button", { name: "Show months" })).toBeVisible();
    await page.getByRole("button", { name: "Show months" }).click();
    await expect(page.getByRole("button", { name: "Hide months" })).toBeVisible();

    await page.getByRole("button", { name: "Hide months" }).click();
    await expect(page.getByRole("button", { name: "Show months" })).toBeVisible();
  });

  test("commit pane shows sync now button", async ({ page }) => {
    await page.getByRole("button", { name: "Show settings and commits" }).click();
    await expect(page.getByRole("button", { name: "Sync now" })).toBeVisible();
  });
});
