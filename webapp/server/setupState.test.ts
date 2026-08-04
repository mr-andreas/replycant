import { describe, expect, it } from "vitest";
import { createSetupState, deriveLfsBaseUrl } from "./setupState";

describe("deriveLfsBaseUrl", () => {
  it("keeps protocol and port while forcing /lfs path", () => {
    expect(deriveLfsBaseUrl("https://git.example:8443/repo.git")).toBe("https://git.example:8443/lfs");
  });

  it("drops credentials, path, and query", () => {
    expect(deriveLfsBaseUrl("https://user:pass@git.example/a/b?x=1")).toBe("https://git.example/lfs");
  });
});

describe("createSetupState", () => {
  it("derives lfsBaseUrl from discovered git url", () => {
    const state = createSetupState();
    state.setDiscoveredConfig({
      ca: "pem",
      url: "https://git.example:8443/repo.git",
    });
    expect(state.getConfig().lfsBaseUrl).toBe("https://git.example:8443/lfs");
  });
});
