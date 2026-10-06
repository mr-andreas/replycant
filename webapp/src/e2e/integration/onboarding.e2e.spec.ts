import { expect, pairDesktop, test } from "./desktop";

// The whole first-run path a desktop user takes: a fresh install mints an
// identity, is approved from another device, joins the tailnet, and clones
// the library through it.
test("pairs a fresh desktop install and opens the library", async ({
  desktopPage,
  provisionWebappIdentity,
}) => {
  await pairDesktop(desktopPage, "e2e-integration", provisionWebappIdentity);
  await expect(desktopPage.getByRole("tab")).toHaveCount(0);
});
