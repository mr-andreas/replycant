import { describe, expect, it } from "vitest";
import { readHashParams, writeHashParam } from "./hashState";

describe("hashState helpers", () => {
  it("reads URL hash params into URLSearchParams", () => {
    window.history.replaceState(null, "", "#k=item-7&o=12");
    const params = readHashParams();
    expect(params.get("k")).toBe("item-7");
    expect(params.get("o")).toBe("12");
  });

  it("writes and updates one hash param while preserving others", () => {
    window.history.replaceState(null, "", "#k=item-2");
    writeHashParam("sp", "1");
    expect(window.location.hash).toContain("k=item-2");
    expect(window.location.hash).toContain("sp=1");
  });

  it("deletes a hash param when set to null", () => {
    window.history.replaceState(null, "", "#k=item-2&sp=1");
    writeHashParam("sp", null);
    expect(window.location.hash).toContain("k=item-2");
    expect(window.location.hash).not.toContain("sp=");
  });
});
