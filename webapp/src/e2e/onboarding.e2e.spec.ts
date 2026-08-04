import { test, expect, E2E_IDENTITY_PASSWORD } from "./fixtures";

test.describe("Onboarding", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.evaluate(() => {
      localStorage.clear();
      sessionStorage.clear();
    });
  });

  test("fresh load shows server URL form", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Continue" })).toBeVisible();
    await expect(page.getByPlaceholder("http://replycant.local:8080")).toBeVisible();
  });

  test("server URL validation rejects empty input", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByRole("button", { name: "Continue" }).click();
    await expect(page.locator(".setup-error")).toHaveText("Server URL is required.");
  });

  test("server URL validation rejects malformed input", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByPlaceholder("http://replycant.local:8080").fill("not-a-url");
    await page.getByRole("button", { name: "Continue" }).click();
    await expect(page.locator(".setup-error")).toHaveText("Server URL must be a valid URL.");
  });

  test("successful discovery navigates to create identity", async ({ page }) => {
    await page.route("**/api/setup/discover", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ca: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n",
          url: "https://localhost:18443",
        }),
      }),
    );
    await page.route("**/api/setup/configure", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
    );

    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByPlaceholder("http://replycant.local:8080").fill("http://localhost:18080");
    await page.getByRole("button", { name: "Continue" }).click();

    await expect(page.getByRole("button", { name: "Generate keypair" })).toBeVisible();
    await expect(page.getByPlaceholder("replycant-webapp")).toBeVisible();
    await expect(page.getByLabel("Password")).toBeVisible();
  });

  test("start over returns to server URL step from create identity", async ({ page }) => {
    await page.route("**/api/setup/discover", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ca: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n",
          url: "https://localhost:18443",
        }),
      }),
    );
    await page.route("**/api/setup/configure", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
    );

    await page.goto("/");
    await page.getByPlaceholder("http://replycant.local:8080").fill("http://localhost:18080");
    await page.getByRole("button", { name: "Continue" }).click();
    await expect(page.getByRole("button", { name: "Generate keypair" })).toBeVisible();

    await page.getByRole("button", { name: "Start over" }).click();

    await expect(page.getByRole("button", { name: "Continue" })).toBeVisible();
    await expect(page.getByPlaceholder("http://replycant.local:8080")).toHaveValue("");
  });

  test("server URL form submits on Enter key", async ({ page }) => {
    await page.route("**/api/setup/discover", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ca: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n",
          url: "https://localhost:18443",
        }),
      }),
    );
    await page.route("**/api/setup/configure", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
    );

    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible();
    await page.getByPlaceholder("http://replycant.local:8080").fill("http://localhost:18080");
    await page.getByPlaceholder("http://replycant.local:8080").press("Enter");

    await expect(page.getByRole("button", { name: "Generate keypair" })).toBeVisible();
  });

  test("discovery failure shows error", async ({ page }) => {
    await page.route("**/api/setup/discover", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "Connection refused" }),
      }),
    );

    await page.goto("/");
    await page.getByPlaceholder("http://replycant.local:8080").fill("http://localhost:18080");
    await page.getByRole("button", { name: "Continue" }).click();
    await expect(page.locator(".setup-error")).toHaveText("Connection refused");
  });

  test("full flow through to QR screen", async ({ page }) => {
    await page.route("**/api/setup/discover", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ca: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n",
          url: "https://localhost:18443",
        }),
      }),
    );
    await page.route("**/api/setup/configure", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
    );

    await page.goto("/");
    await page.getByPlaceholder("http://replycant.local:8080").fill("http://localhost:18080");
    await page.getByRole("button", { name: "Continue" }).click();
    await expect(page.getByRole("button", { name: "Generate keypair" })).toBeVisible();

    await page.getByPlaceholder("replycant-webapp").fill("e2e-device");
    await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
    await page.getByRole("button", { name: "Generate keypair" }).click();

    await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible();
    await expect(page.locator("svg")).toBeVisible();
    await expect(page.locator(".setup-error")).toHaveCount(0);
  });
});
