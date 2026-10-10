import { _electron as electron, ElectronApplication, Page } from "@playwright/test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { IDENTITY_STORAGE_KEY } from "../../lib/identity";
import { expect, test as base, E2E_IDENTITY_PASSWORD } from "../fixtures";

export const RENDERER_PORT = 5182;
export const RENDERER_URL = `http://127.0.0.1:${RENDERER_PORT}`;
export const API_URL = `http://127.0.0.1:${RENDERER_PORT + 1}`;

const ELECTRON_MAIN = resolve(process.cwd(), "dist-electron/dev-main.js");

// gitd publishes pairing records to the container's fake discovery service.
// Chromium sends every slot subdomain of it to the published port, which is
// how the renderer finds a record without any DNS on the host.
const DISCOVERY_BASE_URL = "http://discovery.test:18082";

// Launches the desktop shell with a throwaway profile so each test pairs from
// nothing, the way a fresh install does.
//
// The mock keychain keeps macOS from prompting for keychain access, which an
// unattended run cannot answer. --no-sandbox is required because Linux CI
// cannot use Electron's setuid sandbox helper from node_modules.
const launchDesktopApp = async (): Promise<{ app: ElectronApplication; userDataDir: string }> => {
  const userDataDir = mkdtempSync(join(tmpdir(), "replycant-desktop-it-"));
  const app = await electron.launch({
    args: [
      ELECTRON_MAIN,
      `--user-data-dir=${userDataDir}`,
      "--use-mock-keychain",
      "--no-sandbox",
      "--host-resolver-rules=MAP *.discovery.test 127.0.0.1",
    ],
    env: {
      ...process.env,
      ELECTRON_RENDERER_URL: RENDERER_URL,
      REPLYCANT_DESKTOP_API: API_URL,
      REPLYCANT_DISCOVERY_BASE_URL: DISCOVERY_BASE_URL,
    },
  });
  return { app, userDataDir };
};

export const test = base.extend<{ desktopPage: Page }>({
  desktopPage: async ({}, use) => {
    const { app, userDataDir } = await launchDesktopApp();
    try {
      await use(await app.firstWindow());
    } finally {
      await app.close();
      rmSync(userDataDir, { recursive: true, force: true });
    }
  },
});

export { expect };

// Takes a fresh desktop install through pairing up to the library shell.
//
// Approval comes from the provisioner in the container, standing in for the
// phone that would scan the QR: it commits the identity and hands gitd the
// pairing secret, so the record reaches the app through discovery exactly as
// in production.
export const pairDesktop = async (
  page: Page,
  deviceName: string,
  provision: (identity: Record<string, unknown>, pairingSecret: string) => void,
): Promise<void> => {
  await expect(page.getByRole("heading", { name: "Replycant setup" })).toBeVisible({ timeout: 30_000 });
  await page.getByPlaceholder("replycant-webapp").fill(deviceName);
  const password = page.getByLabel("Password");
  if (await password.isVisible()) {
    await password.fill(E2E_IDENTITY_PASSWORD);
  }
  await page.getByRole("button", { name: "Generate keypair" }).click();

  await expect(page.getByRole("heading", { name: "Authorize this device" })).toBeVisible({ timeout: 10_000 });
  const payload = JSON.parse((await page.getByTestId("pairing-qr").getAttribute("data-payload")) ?? "{}");
  expect(payload.pairing_secret).toBeTruthy();
  const identity = await page.evaluate(
    (key) => JSON.parse(localStorage.getItem(key) ?? "null"),
    IDENTITY_STORAGE_KEY,
  );
  expect(identity?.publicKeySsh).toBeTruthy();

  provision(identity, payload.pairing_secret);

  await expect(page.locator(".brand-wordmark")).toHaveText("Replycant", { timeout: 120_000 });
};
