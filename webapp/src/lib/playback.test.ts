import { describe, expect, it } from "vitest";
import { selectPlaybackStrategy } from "./playback";

describe("playback strategy selection", () => {
  it("defaults to direct play", () => {
    expect(selectPlaybackStrategy()).toBe("directPlay");
  });
});
