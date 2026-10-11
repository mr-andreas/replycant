import type { Page } from "@playwright/test";
import { test, expect, E2E_IDENTITY_PASSWORD, stubDesktopBridgeOn } from "./fixtures";

// Keeps pairing polls off the real discovery service. A 404 is what it answers
// until a phone approves, so the app stays on the QR screen.
const routeDiscoveryAsPending = async (page: Page) => {
  await page.route("https://*.discovery.replycant.com/**", (route) =>
    route.fulfill({ status: 404, headers: { "access-control-allow-origin": "*" }, body: "" }),
  );
};

test.describe("Onboarding", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.evaluate(() => {
      localStorage.clear();
      sessionStorage.clear();
    });
  });

  // A library is only reachable over its tailnet, which a browser cannot
  // join, so the browser build must say so instead of offering a setup it
  // cannot finish.
  test("plain browser is told the desktop app is required", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Desktop app required" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Generate keypair" })).toHaveCount(0);
  });

  test.describe("in the desktop shell", () => {
    test.beforeEach(async ({ page }) => {
      await stubDesktopBridgeOn(page);
      await routeDiscoveryAsPending(page);
    });

    test("fresh install starts at identity creation", async ({ page }) => {
      await page.goto("/");
      await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
      await expect(page.getByPlaceholder("replycant-webapp")).toBeVisible();
      await expect(page.getByLabel("Password")).toBeVisible();
    });

    // The QR is the only way a desktop gets approved, and it must carry the
    // pairing secret the approving phone hands to gitd.
    test("creating an identity shows the pairing QR", async ({ page }) => {
      await page.goto("/");
      await page.getByPlaceholder("replycant-webapp").fill("e2e-device");
      await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
      await page.getByRole("button", { name: "Generate keypair" }).click();

      await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible();
      const payload = JSON.parse((await page.getByTestId("pairing-qr").getAttribute("data-payload")) ?? "{}");
      expect(payload.pairing_secret).toBeTruthy();
      await expect(page.locator(".setup-error")).toHaveCount(0);
    });

    test("start over returns from the QR to identity creation", async ({ page }) => {
      await page.goto("/");
      await page.getByPlaceholder("replycant-webapp").fill("e2e-device");
      await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
      await page.getByRole("button", { name: "Generate keypair" }).click();
      await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible();

      await page.getByRole("button", { name: "Start over" }).click();

      await expect(page.getByRole("button", { name: "Generate keypair" })).toBeVisible();
    });
  });
});
