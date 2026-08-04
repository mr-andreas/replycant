import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MonthEntry } from "../lib/timeline";
import { MonthSidebar } from "./MonthSidebar";

const months: MonthEntry[] = [
  { yearKey: "2026", monthKey: "2026-01", count: 12, firstTakenAt: "2026-01-01T00:00:00Z", globalOffset: 0 },
  { yearKey: "2026", monthKey: "2026-02", count: 8, firstTakenAt: "2026-02-03T00:00:00Z", globalOffset: 12 },
  { yearKey: "2027", monthKey: "2027-01", count: 3, firstTakenAt: "2027-01-10T00:00:00Z", globalOffset: 20 },
];

describe("MonthSidebar", () => {
  it("calls onSelectMonth when a month is clicked", () => {
    const onSelectMonth = vi.fn();
    render(<MonthSidebar months={months} currentMonthKey={null} onSelectMonth={onSelectMonth} />);

    fireEvent.click(screen.getByRole("button", { name: /feb/i }));
    expect(onSelectMonth).toHaveBeenCalledWith("2026-02");
  });

  it("highlights the active month", () => {
    render(<MonthSidebar months={months} currentMonthKey="2026-02" onSelectMonth={vi.fn()} />);

    expect(screen.getByRole("button", { name: /feb/i })).toHaveClass("active");
    expect(screen.getByRole("button", { name: /jan\s*12/i })).not.toHaveClass("active");
  });

  it("renders draggable overlay scrollbar when month list overflows", async () => {
    const denseMonths: MonthEntry[] = Array.from({ length: 36 }, (_, index) => {
      const month = (index % 12) + 1;
      const year = 2025 + Math.floor(index / 12);
      const monthKey = `${year}-${String(month).padStart(2, "0")}`;
      return {
        yearKey: String(year),
        monthKey,
        count: index + 1,
        firstTakenAt: `${monthKey}-01T00:00:00Z`,
        globalOffset: index * 10,
      };
    });
    const { container } = render(<MonthSidebar months={denseMonths} currentMonthKey={null} onSelectMonth={vi.fn()} />);
    const sidebar = screen.getByTestId("timeline-month-sidebar");
    Object.defineProperty(sidebar, "clientHeight", { configurable: true, value: 240 });
    Object.defineProperty(sidebar, "scrollHeight", { configurable: true, value: 1200 });
    fireEvent.scroll(sidebar);

    await waitFor(() => {
      expect(container.querySelector(".timeline-scrollbar-thumb")).not.toBeNull();
    });
  });
});
