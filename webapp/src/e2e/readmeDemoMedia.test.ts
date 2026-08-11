import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  buildEncryptedDemoByOid,
  listDemoMediaPaths,
  oidForSeedIndex,
  resolveOidFromLfsUrl,
} from "./readmeDemoMedia";

// Verifies README screenshot seeding maps each timeline OID to a distinct demo JPEG
// so the Electron capture shows real photos instead of identical placeholder thumbs.
describe("readmeDemoMedia", () => {
  it("lists committed iOS ScreenshotMedia demo JPEGs in stable order", () => {
    const paths = listDemoMediaPaths();
    expect(paths.length).toBeGreaterThanOrEqual(8);
    expect(paths.every((path) => path.endsWith(".jpg"))).toBe(true);
    expect(paths).toEqual([...paths].sort((a, b) => a.localeCompare(b)));
    for (const path of paths.slice(0, 3)) {
      expect(readFileSync(path).byteLength).toBeGreaterThan(1000);
    }
  });

  it("derives the same OID scheme as uniqueThumbnailSha timeline seeds", () => {
    expect(oidForSeedIndex(0)).toBe("0".repeat(64));
    expect(oidForSeedIndex(1)).toBe(`${"0".repeat(63)}1`);
    expect(oidForSeedIndex(21)).toBe(`${"0".repeat(62)}21`);
  });

  it("extracts OID from LFS object URLs used by AuthImage", () => {
    const oid = "a".repeat(64);
    expect(
      resolveOidFromLfsUrl(`http://127.0.0.1:5181/api/lfs/objects/${oid}/data`),
    ).toBe(oid);
    expect(resolveOidFromLfsUrl("https://example.com/other")).toBeNull();
  });

  it("encrypts each demo JPEG under its seed OID so routed bodies differ", async () => {
    const paths = listDemoMediaPaths().slice(0, 3);
    const byOid = await buildEncryptedDemoByOid(paths);
    expect(byOid.size).toBe(3);

    const bodies = [...byOid.values()];
    expect(bodies[0]!.byteLength).toBeGreaterThan(1000);
    expect(Buffer.from(bodies[0]!).equals(Buffer.from(bodies[1]!))).toBe(false);
    expect(byOid.has(oidForSeedIndex(0))).toBe(true);
    expect(byOid.has(oidForSeedIndex(1))).toBe(true);
    expect(byOid.has(oidForSeedIndex(2))).toBe(true);
  });

  it("cycles demo paths when seeding denser timeline grids", async () => {
    const paths = listDemoMediaPaths().slice(0, 2);
    const byOid = await buildEncryptedDemoByOid(paths, 5);
    expect(byOid.size).toBe(5);
    expect(byOid.has(oidForSeedIndex(4))).toBe(true);
  });
});
