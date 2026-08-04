import type { Page } from "@playwright/test";
import { test, expect, E2E_IDENTITY_PASSWORD } from "../fixtures";

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

test.describe("@integration Full onboarding against real backend", () => {
  test.setTimeout(120_000);

  test("complete onboarding flow with provisioner authorization", async ({
    page,
    provisionWebappIdentity,
  }) => {
    await page.goto("/");
    await page.evaluate(() => {
      localStorage.clear();
      sessionStorage.clear();
    });
    await page.goto("/");

    // Server URL discovery.
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByPlaceholder("http://replycant.local:8080").fill(CASERVER_URL);
    await continueToCreateStep(page);

    // Identity creation.
    await page.getByPlaceholder("replycant-webapp").fill("e2e-integration");
    await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
    await page.getByRole("button", { name: "Generate keypair" }).click();

    // QR screen — identity is now in localStorage.
    await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(".setup-error")).toHaveCount(0);

    // Extract identity from localStorage and authorize via provisioner inside the container.
    const webappIdentity = await page.evaluate((key) => {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    }, IDENTITY_STORAGE_KEY);

    expect(webappIdentity).toBeTruthy();
    expect(webappIdentity.publicKeySsh).toBeTruthy();
    expect(webappIdentity.agePublicKey).toBeTruthy();

    provisionWebappIdentity(webappIdentity);

    // Wait for the app to detect authorization and transition past the QR screen.
    // The rehydrating screen may flash briefly or the app may go straight to ready.
    await expect(
      page.locator(".brand-wordmark")
        .or(page.getByRole("heading", { name: "Setting up your library" })),
    ).toBeVisible({ timeout: 30_000 });

    // Wait for rehydration to complete and the main app shell to appear.
    await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 60_000 });
    await expect(page.getByRole("tab")).toHaveCount(0);
  });
});
