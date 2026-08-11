import { test as base, expect, Page, Route } from "@playwright/test";
import { execSync } from "node:child_process";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import { IDENTITY_PBKDF2_ITERATIONS, IDENTITY_STORAGE_KEY } from "../lib/identity";

const CONTAINER_ID_PATH = "/tmp/pw-integration-container-id";

const SETUP_CONFIG_STORAGE_KEY = "replycant.setup.config";

// Shared password for seeded e2e identities so Playwright can unlock after seeding.
export const E2E_IDENTITY_PASSWORD = "e2e-password";

const FAKE_SETUP_CONFIG = {
  serverUrl: "http://localhost:18080",
  ca: "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n",
  url: "https://localhost:18443",
};

// Builds a v2 password-wrapped identity so bypass tests never seed cleartext secrets.
const buildFakeEncryptedIdentity = async (): Promise<Record<string, unknown>> => {
  const secret = {
    privateKeyPem: "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
    certificatePem: "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n",
    agePrivateKeyBase64: "AAAA",
  };
  const salt = webcrypto.getRandomValues(new Uint8Array(16));
  const iv = webcrypto.getRandomValues(new Uint8Array(12));
  const keyMaterial = await webcrypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(E2E_IDENTITY_PASSWORD),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  const key = await webcrypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      salt,
      iterations: IDENTITY_PBKDF2_ITERATIONS,
      hash: "SHA-256",
    },
    keyMaterial,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const ciphertext = await webcrypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(JSON.stringify(secret)),
  );
  const toB64 = (bytes: Uint8Array | ArrayBuffer): string =>
    Buffer.from(bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : bytes).toString("base64");
  return {
    version: 2,
    publicKeySsh: "ecdsa-sha2-nistp256 AAAA",
    agePublicKey: "age1fake",
    deviceName: "e2e-test",
    deviceUUID: "00000000-0000-4000-8000-000000000000",
    createdAt: new Date().toISOString(),
    wrap: "password",
    encryptedPayloadBase64: toB64(ciphertext),
    ivBase64: toB64(iv),
    saltBase64: toB64(salt),
  };
};

let cachedFakeIdentity: Record<string, unknown> | null = null;

const getFakeEncryptedIdentity = async (): Promise<Record<string, unknown>> => {
  if (!cachedFakeIdentity) {
    cachedFakeIdentity = await buildFakeEncryptedIdentity();
  }
  return cachedFakeIdentity;
};

// Minimal git smart HTTP response advertising zero refs (empty repository).
const EMPTY_REPO_INFO_REFS =
  "001e# service=git-upload-pack\n0000";

// Clears all persisted browser state so each test starts from a blank slate.
async function resetBrowserState(page: Page): Promise<void> {
  await page.goto("/");
  await page.evaluate(async () => {
    const deleteDatabase = async (name: string): Promise<void> =>
      new Promise((resolve) => {
        const request = indexedDB.deleteDatabase(name);
        request.onsuccess = () => resolve();
        request.onerror = () => resolve();
        request.onblocked = () => resolve();
      });
    const names = new Set<string>(["gitdb-sync-v1", "gitdb-entities", "replycant-git-v3"]);
    if (typeof indexedDB.databases === "function") {
      const databases = await indexedDB.databases();
      for (const database of databases) {
        if (!database.name) continue;
        if (database.name.startsWith("gitdb") || database.name.startsWith("replycant-git")) {
          names.add(database.name);
        }
      }
    }
    for (const name of names) {
      await deleteDatabase(name);
    }
    localStorage.clear();
    sessionStorage.clear();
  });
}

// Seeds encrypted localStorage and mocks API endpoints so shell tests can unlock into the main app.
export async function setupOnboardingBypass(page: Page): Promise<void> {
  const identityValue = await getFakeEncryptedIdentity();
  await page.addInitScript(
    ({ configKey, configValue, identityKey, identityRecord }) => {
      localStorage.setItem(configKey, JSON.stringify(configValue));
      localStorage.setItem(identityKey, JSON.stringify(identityRecord));
    },
    {
      configKey: SETUP_CONFIG_STORAGE_KEY,
      configValue: FAKE_SETUP_CONFIG,
      identityKey: IDENTITY_STORAGE_KEY,
      identityRecord: identityValue,
    },
  );

  await page.route("**/api/setup/configure", (route: Route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  await page.route("**/api/setup/session", (route: Route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true }),
      headers: { "set-cookie": "replycant_session=e2e; Path=/; HttpOnly; SameSite=Strict" },
    }),
  );

  await page.route("**/api/git/info/refs*", (route: Route) =>
    route.fulfill({
      status: 200,
      contentType: "application/x-git-upload-pack-advertisement",
      body: EMPTY_REPO_INFO_REFS,
    }),
  );

  await page.route("**/api/git/git-upload-pack", (route: Route) =>
    route.fulfill({ status: 200, contentType: "application/x-git-upload-pack-result", body: "0000" }),
  );
}

// Unlocks a seeded password-wrapped identity so bypassed tests reach the main shell.
// Safe to call after reloads: no-ops when the shell is already visible.
export async function unlockBypassIdentity(page: Page): Promise<void> {
  const unlockHeading = page.getByRole("heading", { name: "Unlock Replycant" });
  const brand = page.locator(".brand-wordmark");
  await expect(unlockHeading.or(brand)).toBeVisible({ timeout: 15_000 });
  if (!(await unlockHeading.isVisible())) return;
  await page.getByLabel("Password").fill(E2E_IDENTITY_PASSWORD);
  await page.getByRole("button", { name: "Unlock" }).click();
}

// Registers page.route handlers that return mock responses for common API endpoints.
async function setupMockApi(
  page: Page,
  overrides: Record<string, (route: Route) => Promise<void> | void> = {},
): Promise<void> {
  for (const [pattern, handler] of Object.entries(overrides)) {
    await page.route(pattern, handler);
  }
}

// Runs a command inside the integration Docker container started by global-setup.
function containerExec(...args: string[]): string {
  const containerID = readFileSync(CONTAINER_ID_PATH, "utf-8").trim();
  return execSync(`docker exec ${containerID} ${args.join(" ")}`)
    .toString()
    .trim();
}

// Pipes stdin content into a file inside the integration container.
function containerWriteFile(path: string, content: string): void {
  const containerID = readFileSync(CONTAINER_ID_PATH, "utf-8").trim();
  execSync(`docker exec -i ${containerID} sh -c 'cat > ${path}'`, { input: content });
}

// Maps webapp IdentityStorageRecord fields to Go gitcrypt.Identity JSON for provisioner.
function mapWebappIdentityToGoFormat(webappIdentity: Record<string, unknown>): string {
  return JSON.stringify({
    publicKeySSH: webappIdentity.publicKeySsh,
    agePublicKey: webappIdentity.agePublicKey,
    agePrivateKeyBase64: webappIdentity.agePrivateKeyBase64 ?? "",
    deviceName: webappIdentity.deviceName,
    deviceUUID: webappIdentity.deviceUUID,
  });
}

// Authorizes a webapp identity inside the integration container using the provisioner tool.
function provisionWebappIdentity(webappIdentity: Record<string, unknown>): void {
  const goIdentityJSON = mapWebappIdentityToGoFormat(webappIdentity);
  containerWriteFile("/tmp/webapp-identity.json", goIdentityJSON);
  containerExec(
    "provisioner",
    "--seeder-identity-dir=/tmp/identity",
    "--new-identity-json=/tmp/webapp-identity.json",
    "--bare-repo=/tmp/repo.git",
  );
}

export const test = base.extend<{
  resetState: void;
  bypassOnboarding: void;
  mockApi: (overrides?: Record<string, (route: Route) => Promise<void> | void>) => Promise<void>;
  containerExec: (...args: string[]) => string;
  provisionWebappIdentity: (identity: Record<string, unknown>) => void;
}>({
  resetState: [
    async ({ page }, use) => {
      await resetBrowserState(page);
      await use();
    },
    { auto: false },
  ],

  bypassOnboarding: [
    async ({ page }, use) => {
      await setupOnboardingBypass(page);
      await use();
    },
    { auto: false },
  ],

  mockApi: async ({ page }, use) => {
    await use((overrides) => setupMockApi(page, overrides));
  },

  containerExec: async ({}, use) => {
    await use(containerExec);
  },

  provisionWebappIdentity: async ({}, use) => {
    await use(provisionWebappIdentity);
  },
});

export { expect } from "@playwright/test";
