import { describe, expect, it } from "vitest";
import { previewTakenAtSchedule } from "./timelineSeed";

// Keeps README month-density seeding varied so marketing screenshots look like a real library.
describe("timelineSeed month density", () => {
  it("varies items per month within the configured range", () => {
    const schedule = previewTakenAtSchedule(0, {
      monthCount: 12,
      itemsPerMonth: { min: 20, max: 50 },
    });
    const counts = new Map<string, number>();
    for (const takenAt of schedule) {
      const monthKey = takenAt.slice(0, 7);
      counts.set(monthKey, (counts.get(monthKey) ?? 0) + 1);
    }
    expect(counts.size).toBe(12);
    const values = [...counts.values()];
    expect(Math.min(...values)).toBeGreaterThanOrEqual(20);
    expect(Math.max(...values)).toBeLessThanOrEqual(50);
    expect(new Set(values).size).toBeGreaterThan(1);
  });
});
