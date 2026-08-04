import { beforeEach, describe, expect, it } from "vitest";
import { LAST_PAGE_STORAGE_KEY, readLastPage, writeLastPage } from "./lastPage";

// Clears persisted page snapshots so each test asserts one behavior in isolation.
const resetLastPageStorage = () => {
  localStorage.removeItem(LAST_PAGE_STORAGE_KEY);
};

describe("last page persistence", () => {
  beforeEach(() => {
    resetLastPageStorage();
  });

  it("returns null when no persisted page exists", () => {
    expect(readLastPage()).toBeNull();
  });

  it("reads a persisted page snapshot", () => {
    localStorage.setItem(
      LAST_PAGE_STORAGE_KEY,
      JSON.stringify({ activeView: "timeline", hash: "#k=item-1&o=0&t=2026-03-15T00:00:00Z" }),
    );

    expect(readLastPage()).toEqual({
      activeView: "timeline",
      hash: "#k=item-1&o=0&t=2026-03-15T00:00:00Z",
    });
  });

  it("writes a page snapshot", () => {
    writeLastPage({ activeView: "albums", hash: "#v=item-2" });

    expect(localStorage.getItem(LAST_PAGE_STORAGE_KEY)).toBe(
      JSON.stringify({ activeView: "albums", hash: "#v=item-2" }),
    );
  });

  it("round-trips write and read", () => {
    const expected = { activeView: "favorites", hash: "#k=item-4&o=2&t=2026-04-01T00:00:00Z&v=item-4" };

    writeLastPage(expected);

    expect(readLastPage()).toEqual(expected);
  });

  it("returns null for malformed persisted data", () => {
    localStorage.setItem(LAST_PAGE_STORAGE_KEY, "{bad-json");

    expect(readLastPage()).toBeNull();
  });
});
