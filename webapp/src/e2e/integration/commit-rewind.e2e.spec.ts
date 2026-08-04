import type { Page } from "@playwright/test";
import { expect, test, E2E_IDENTITY_PASSWORD } from "../fixtures";

const CASERVER_URL = "http://localhost:18080";
const IDENTITY_STORAGE_KEY = "replycant.identity.v1";

// Retries server discovery because integration backend startup can lag briefly.
// The Continue button shows a spinner while discovery is in flight, so after
// each click we wait for the old error to clear (confirming the fetch started),
// then wait for a fresh outcome (new error or next step).
const continueToCreateStep = async (page: Page) => {
  const continueButton = page.getByRole("button", { name: "Continue" });
  const generateButton = page.getByRole("button", { name: "Generate keypair" });
  const setupError = page.locator(".setup-error");
  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (await generateButton.isVisible()) return;
    if (!(await continueButton.isVisible())) break;
    await continueButton.click();
    await setupError.waitFor({ state: "detached", timeout: 5_000 }).catch(() => {});
    await setupError.or(generateButton).waitFor({ state: "visible", timeout: 30_000 });
    if (await generateButton.isVisible()) return;
    if (await setupError.isVisible()) {
      const message = (await setupError.innerText()).trim();
      if (!message.startsWith("Failed to fetch server configuration:")) {
        throw new Error(`Unexpected setup error: ${message}`);
      }
    }
    await page.waitForTimeout(1_000);
  }
  await expect(generateButton).toBeVisible({ timeout: 10_000 });
};

test.describe("@integration Commit rewind setup against real backend", () => {
  test.setTimeout(180_000);

  test("seeds git history and opens commit list", async ({ page, containerExec, provisionWebappIdentity, browserName }) => {
    test.skip(browserName !== "chromium", "This test mutates a shared integration repository.");
    containerExec(
      "seeder",
      "--add-media-only",
      "--bare-repo=/tmp/repo.git",
      "--output-dir=/tmp/identity",
      "--device-space=e2e-device",
      "--media-count=1000",
      "--commit-count=10",
    );

    await page.goto("/");
    await page.evaluate(() => {
      localStorage.clear();
      sessionStorage.clear();
    });
    await page.goto("/");

    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByPlaceholder("http://replycant.local:8080").fill(CASERVER_URL);
    await continueToCreateStep(page);

    await page.getByPlaceholder("replycant-webapp").fill("e2e-commit-rewind");
    await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
    await page.getByRole("button", { name: "Generate keypair" }).click();

    await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible({ timeout: 10_000 });
    const webappIdentity = await page.evaluate((key) => {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    }, IDENTITY_STORAGE_KEY);
    expect(webappIdentity).toBeTruthy();
    provisionWebappIdentity(webappIdentity);

    await expect(
      page.locator(".brand-wordmark")
        .or(page.getByRole("heading", { name: "Setting up your library" })),
    ).toBeVisible({ timeout: 30_000 });

    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 60_000 });
    await expect(page.locator("main.timeline")).toBeVisible();
    await expect(page.locator("main.timeline button.image-tile").first()).toBeVisible({ timeout: 30_000 });

    await page.getByRole("button", { name: "Show settings and commits" }).click();
    await expect(page.locator("aside[aria-label='Commit history']")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Sync & commits" })).toBeVisible();
  });
});
