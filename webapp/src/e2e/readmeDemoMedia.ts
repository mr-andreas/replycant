import type { Page, Route } from "@playwright/test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { encryptBinaryChunked } from "../modules/gitdb/testEncryption";

// Resolved from the webapp package root (vitest/playwright cwd) so unit tests and
// Electron capture share one path without depending on transformed import.meta.url.
const DEMO_MEDIA_DIR = resolve(process.cwd(), "../iosapp/iosapp/ScreenshotMedia");

// Locates sanitized iOS demo JPEGs so README Electron screenshots reuse the same
// committed media as App Store capture instead of inventing a second asset tree.
export const listDemoMediaPaths = (): string[] =>
  readdirSync(DEMO_MEDIA_DIR)
    .filter((name) => /^demo-\d+\.jpg$/i.test(name))
    .sort((a, b) => a.localeCompare(b))
    .map((name) => join(DEMO_MEDIA_DIR, name));

// Mirrors timelineSeed uniqueThumbnailSha OIDs so routed LFS bodies match seeded pointers.
export const oidForSeedIndex = (index: number): string =>
  `${String(index).padStart(64, "0")}`.slice(-64);

// Pulls the object id from AuthImage LFS URLs so the route table can fulfill by OID.
export const resolveOidFromLfsUrl = (url: string): string | null => {
  const match = url.match(/\/api\/lfs\/objects\/([0-9a-f]{64})(?:\/|$)/i);
  return match?.[1]?.toLowerCase() ?? null;
};

// Encrypts demo JPEGs under seed OIDs so Playwright can serve decryptable LFS bodies.
// itemCount may exceed demoPaths.length; paths cycle so denser timeline grids stay photorealistic.
// Ciphertext is reused per source path so large README seeds stay fast to encrypt.
export const buildEncryptedDemoByOid = async (
  demoPaths: string[] = listDemoMediaPaths(),
  itemCount = demoPaths.length,
): Promise<Map<string, Uint8Array>> => {
  if (demoPaths.length === 0) {
    throw new Error("no demo media paths available for README screenshot seeding");
  }
  const byOid = new Map<string, Uint8Array>();
  const encryptedByPath = new Map<string, Uint8Array>();
  for (let index = 0; index < itemCount; index += 1) {
    const path = demoPaths[index % demoPaths.length]!;
    let encrypted = encryptedByPath.get(path);
    if (!encrypted) {
      const plaintext = new Uint8Array(readFileSync(path));
      encrypted = await encryptBinaryChunked(plaintext);
      encryptedByPath.set(path, encrypted);
    }
    byOid.set(oidForSeedIndex(index), encrypted);
  }
  return byOid;
};

// Serves encrypted demo thumbnails for README capture so the timeline grid shows real photos.
export const routeDemoThumbnails = async (
  page: Page,
  encryptedByOid: Map<string, Uint8Array>,
): Promise<void> => {
  await page.route("**/api/lfs/objects/**", async (route: Route) => {
    const oid = resolveOidFromLfsUrl(route.request().url());
    const body = oid ? encryptedByOid.get(oid) : undefined;
    if (!body) {
      await route.fulfill({ status: 404, body: "missing demo oid" });
      return;
    }
    await route.fulfill({
      status: 200,
      contentType: "application/octet-stream",
      body: Buffer.from(body),
    });
  });
};
