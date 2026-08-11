import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const README_DIR = resolve(process.cwd(), "../docs/static/img/readme");
const DESKTOP_PATH = resolve(README_DIR, "desktop-timeline.png");
const IOS_PATH = resolve(README_DIR, "ios-timeline.png");
const OUTPUT_PATH = resolve(README_DIR, "apps.png");

// Runs a command and fails with stderr when composition cannot complete.
const run = (command: string, args: string[]): void => {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args[0] ?? ""} failed:\n${result.stderr || result.stdout || "unknown error"}`,
    );
  }
};

// Reads width/height from a PNG so canvas placement can account for shadows.
const imageSize = (path: string): { width: number; height: number } => {
  const result = spawnSync(
    "magick",
    ["identify", "-format", "%w %h", path],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(`magick identify failed for ${path}: ${result.stderr}`);
  }
  const [widthText, heightText] = (result.stdout || "").trim().split(/\s+/);
  const width = Number(widthText);
  const height = Number(heightText);
  if (!Number.isFinite(width) || !Number.isFinite(height)) {
    throw new Error(`could not parse size for ${path}: ${result.stdout}`);
  }
  return { width, height };
};

// Lossy-compresses a PNG in place when pngquant is available so README assets stay small.
const optimizePng = (path: string): void => {
  if (spawnSync("pngquant", ["--version"], { encoding: "utf8" }).status !== 0) {
    console.warn("pngquant not found; skipping lossy PNG optimization");
    return;
  }
  const tempPath = `${path}.pngquant.png`;
  const result = spawnSync(
    "pngquant",
    [
      "--quality=40-85",
      "--speed",
      "1",
      "--force",
      "--skip-if-larger",
      "--output",
      tempPath,
      path,
    ],
    { encoding: "utf8" },
  );
  if (result.status !== 0 || !existsSync(tempPath)) {
    console.warn(`pngquant skipped for ${path}: ${result.stderr || result.stdout}`);
    return;
  }
  renameSync(tempPath, path);
};

// Places the framed iPhone over the Electron window for a single README hero image.
// Layout matches the product mockup: desktop as the base, iOS overlapping the
// bottom-right and slightly overhanging the canvas edge.
const composeReadmeScreenshot = (): void => {
  if (!existsSync(DESKTOP_PATH)) {
    throw new Error(`missing desktop screenshot: ${DESKTOP_PATH}`);
  }
  if (!existsSync(IOS_PATH)) {
    throw new Error(`missing iOS screenshot: ${IOS_PATH}`);
  }
  if (spawnSync("magick", ["-version"], { encoding: "utf8" }).status !== 0) {
    throw new Error("ImageMagick `magick` is required to compose README screenshots");
  }

  mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
  const workDir = mkdtempSync(join(tmpdir(), "replycant-readme-compose-"));
  const iosShadowPath = join(workDir, "ios-shadow.png");

  try {
    const desktop = imageSize(DESKTOP_PATH);
    // Phone height tracks the desktop capture scale (CSS or retina).
    const iosHeight = Math.round(desktop.height * 0.82);

    // Soft shadow so the phone reads as a layer above the desktop window.
    run("magick", [
      IOS_PATH,
      "-resize",
      `x${iosHeight}`,
      "(",
      "+clone",
      "-background",
      "black",
      "-shadow",
      "40x12+10+16",
      ")",
      "+swap",
      "-background",
      "none",
      "-layers",
      "merge",
      "+repage",
      iosShadowPath,
    ]);

    const ios = imageSize(iosShadowPath);
    // Flush desktop to the top-left; hang the phone past the bottom-right edge.
    const iosX = desktop.width - Math.round(ios.width * 0.78);
    const iosY = desktop.height - Math.round(ios.height * 0.72);
    const canvasWidth = Math.max(desktop.width, iosX + ios.width);
    const canvasHeight = Math.max(desktop.height, iosY + ios.height);

    run("magick", [
      "-size",
      `${canvasWidth}x${canvasHeight}`,
      "xc:none",
      DESKTOP_PATH,
      "-geometry",
      "+0+0",
      "-compose",
      "over",
      "-composite",
      iosShadowPath,
      "-geometry",
      `+${iosX}+${iosY}`,
      "-compose",
      "over",
      "-composite",
      // Cap README hero width so GitHub stays snappy without looking soft.
      "-resize",
      "1800x>",
      OUTPUT_PATH,
    ]);

    optimizePng(OUTPUT_PATH);
    optimizePng(DESKTOP_PATH);
    optimizePng(IOS_PATH);

    const finalSize = imageSize(OUTPUT_PATH);
    console.log(
      `wrote ${OUTPUT_PATH} (${finalSize.width}x${finalSize.height})`,
    );
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
};

composeReadmeScreenshot();
