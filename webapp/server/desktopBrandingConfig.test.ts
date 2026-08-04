import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const WEBAPP_ROOT = resolve(import.meta.dirname, "..");
const packageJsonPath = resolve(WEBAPP_ROOT, "package.json");

type DesktopBuildConfig = {
  productName?: string;
  artifactName?: string;
  directories?: {
    buildResources?: string;
  };
  mac?: {
    icon?: string;
    hardenedRuntime?: boolean;
    gatekeeperAssess?: boolean;
    entitlements?: string;
    entitlementsInherit?: string;
    notarize?: boolean;
    target?: string[];
  };
  linux?: {
    icon?: string;
  };
  win?: {
    icon?: string;
  };
  nsis?: {
    artifactName?: string;
    installerIcon?: string;
    uninstallerIcon?: string;
  };
  dmg?: {
    sign?: boolean;
  };
};

type PackageJsonWithBuild = {
  scripts?: Record<string, string>;
  build?: DesktopBuildConfig;
};

const packageJson = JSON.parse(
  readFileSync(packageJsonPath, "utf8"),
) as PackageJsonWithBuild;
const scripts = packageJson.scripts ?? {};
const build = packageJson.build ?? {};
const runtimeMainEntry = readFileSync(
  resolve(WEBAPP_ROOT, "electron/main.ts"),
  "utf8",
);
const runtimeDevMainEntry = readFileSync(
  resolve(WEBAPP_ROOT, "electron/dev-main.ts"),
  "utf8",
);

describe("desktop branding configuration", () => {
  test("sets Replycant as packaged product name", () => {
    expect(build.productName).toBe("Replycant");
  });

  test("declares platform icon paths for electron-builder", () => {
    expect(build.directories?.buildResources).toBe("build");
    expect(build.mac?.icon).toBe("build/icons/icon.icns");
    expect(build.linux?.icon).toBe("build/icons");
    expect(build.win?.icon).toBe("build/icons/icon.ico");
    expect(build.nsis?.installerIcon).toBe("build/icons/icon.ico");
    expect(build.nsis?.uninstallerIcon).toBe("build/icons/icon.ico");
  });

  // Keeps desktop downloads clearly branded without renaming the installed app.
  test("declares desktop artifact filenames for release downloads", () => {
    expect(build.artifactName).toBe(
      "replycant-desktop-v${version}-${arch}.${ext}",
    );
    expect(build.nsis?.artifactName).toBe(
      "replycant-desktop-setup-v${version}-${arch}.${ext}",
    );
  });

  test("enables macOS release signing and notarization settings", () => {
    expect(build.mac?.hardenedRuntime).toBe(true);
    expect(build.mac?.gatekeeperAssess).toBe(false);
    expect(build.mac?.entitlements).toBe("build/entitlements.mac.plist");
    expect(build.mac?.entitlementsInherit).toBe("build/entitlements.mac.plist");
    expect(build.mac?.notarize).toBe(true);
    expect(build.mac?.target).toEqual(["dmg"]);
    expect(build.dmg?.sign).toBe(true);
  });

  test("notarizes and staples DMG artifacts in macOS desktop releases", () => {
    expect(scripts["desktop:dist:mac"]).toContain(
      "npm run desktop:notarize:dmg",
    );
    expect(scripts["desktop:notarize:dmg"]).toContain("notarytool submit");
    expect(scripts["desktop:notarize:dmg"]).toContain("stapler staple");
  });

  test("ships required icon source files", () => {
    expect(existsSync(resolve(WEBAPP_ROOT, "build/icons/icon.png"))).toBe(true);
    expect(existsSync(resolve(WEBAPP_ROOT, "build/icons/icon.icns"))).toBe(true);
    expect(existsSync(resolve(WEBAPP_ROOT, "build/icons/icon.ico"))).toBe(true);
    expect(existsSync(resolve(WEBAPP_ROOT, "build/entitlements.mac.plist"))).toBe(
      true,
    );
  });

  test("sets Replycant app identity in runtime entrypoints", () => {
    expect(runtimeMainEntry).toContain('const APP_NAME = "Replycant";');
    expect(runtimeMainEntry).toContain("app.setName(APP_NAME);");
    expect(runtimeDevMainEntry).toContain('const APP_NAME = "Replycant";');
    expect(runtimeDevMainEntry).toContain("app.setName(APP_NAME);");
  });
});
