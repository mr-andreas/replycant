import { expect, pairDesktop, test } from "./desktop";

// A library with real history has to arrive intact over the tailnet: media
// shows in the timeline and the commit list opens.
test("seeds git history and opens commit list", async ({
  desktopPage: page,
  containerExec,
  provisionWebappIdentity,
}) => {
  containerExec(
    "seeder",
    "--add-media-only",
    "--bare-repo=/tmp/repo.git",
    "--output-dir=/tmp/identity",
    "--device-space=e2e-device",
    "--media-count=1000",
    "--commit-count=10",
  );

  await pairDesktop(page, "e2e-commit-rewind", provisionWebappIdentity);

  await expect(page.locator("main.timeline")).toBeVisible();
  await expect(page.locator("main.timeline button.image-tile").first()).toBeVisible({ timeout: 60_000 });

  await page.getByRole("button", { name: "Show settings and commits" }).click();
  await expect(page.locator("aside[aria-label='Commit history']")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
});
