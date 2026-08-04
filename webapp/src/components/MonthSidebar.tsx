import { memo, useCallback, useEffect, useMemo, useRef } from "react";
import { MonthEntry } from "../lib/timeline";
import { OverlayScrollbar } from "./OverlayScrollbar";

// Defines the sidebar contract so timeline can render month navigation without coupling sidebar internals.
interface MonthSidebarProps {
  months: MonthEntry[];
  currentMonthKey: string | null;
  onSelectMonth: (monthKey: string) => void;
  initialScrollTop?: number;
  onScroll?: (scrollTop: number) => void;
}

// Groups month buckets by year so dense libraries remain scannable in a compact rail.
const groupByYear = (months: MonthEntry[]): Array<{ yearKey: string; months: MonthEntry[] }> => {
  const byYear = new Map<string, MonthEntry[]>();
  for (const month of months) {
    const list = byYear.get(month.yearKey) ?? [];
    list.push(month);
    byYear.set(month.yearKey, list);
  }
  return Array.from(byYear.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([yearKey, yearMonths]) => ({ yearKey, months: yearMonths }));
};

// Formats month labels so the sidebar stays compact while preserving quick month recognition.
const formatMonthLabel = (monthKey: string): string => {
  const [year, month] = monthKey.split("-");
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, 1));
  return date.toLocaleDateString(undefined, { month: "short" });
};

// Builds compact scrub labels so month scrollbar dragging communicates temporal position.
const formatMonthScrollLabel = (monthKey: string): string => {
  const [year, month] = monthKey.split("-");
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, 1));
  return date.toLocaleDateString(undefined, { month: "short", year: "numeric" });
};

// Renders a year-grouped month rail that jumps the timeline and auto-keeps the active month visible.
export const MonthSidebar = memo(({
  months,
  currentMonthKey,
  onSelectMonth,
  initialScrollTop = 0,
  onScroll,
}: MonthSidebarProps) => {
  const sidebarRef = useRef<HTMLElement | null>(null);
  const monthRefs = useRef(new Map<string, HTMLButtonElement>());
  const initialScrollAppliedRef = useRef(false);
  const byYear = useMemo(() => groupByYear(months), [months]);
  const orderedMonthKeys = useMemo(
    () => byYear.flatMap((yearGroup) => yearGroup.months.map((entry) => entry.monthKey)),
    [byYear],
  );

  useEffect(() => {
    if (!currentMonthKey) {
      return;
    }
    const node = monthRefs.current.get(currentMonthKey);
    if (node && typeof node.scrollIntoView === "function") {
      node.scrollIntoView({ block: "nearest" });
    }
  }, [currentMonthKey]);

  // Restores month rail scroll only on first mount so the hash anchor is respected once.
  useEffect(() => {
    if (initialScrollAppliedRef.current) return;
    initialScrollAppliedRef.current = true;
    const sidebar = sidebarRef.current;
    if (!sidebar) return;
    if (initialScrollTop <= 0) return;
    sidebar.scrollTop = initialScrollTop;
  }, [initialScrollTop]);

  // Emits scroll offsets to callers that mirror sidebar state into URL hash.
  const handleSidebarScroll = useCallback(() => {
    const sidebar = sidebarRef.current;
    if (!sidebar || !onScroll) return;
    onScroll(sidebar.scrollTop);
  }, [onScroll]);

  // Resolves visible month context so dragging the month scrollbar has temporal feedback.
  const getScrollLabel = useCallback((): string | null => {
    const sidebar = sidebarRef.current;
    if (!sidebar) {
      return null;
    }
    const top = sidebar.scrollTop;
    let lastVisibleKey: string | null = null;
    for (const monthKey of orderedMonthKeys) {
      const node = monthRefs.current.get(monthKey);
      if (!node) {
        continue;
      }
      lastVisibleKey = monthKey;
      if (node.offsetTop + node.offsetHeight >= top) {
        return formatMonthScrollLabel(monthKey);
      }
    }
    return lastVisibleKey ? formatMonthScrollLabel(lastVisibleKey) : null;
  }, [orderedMonthKeys]);

  return (
    <div className="month-sidebar-viewport">
      <aside
        ref={sidebarRef}
        className="month-sidebar"
        aria-label="Timeline month navigation"
        data-testid="timeline-month-sidebar"
        onScroll={handleSidebarScroll}
      >
        {byYear.map((yearGroup) => (
          <div className="month-sidebar-year-group" key={yearGroup.yearKey}>
            <div className="month-sidebar-year">{yearGroup.yearKey}</div>
            {yearGroup.months.map((entry) => {
              const active = entry.monthKey === currentMonthKey;
              return (
                <button
                  key={entry.monthKey}
                  type="button"
                  ref={(node) => {
                    if (node) {
                      monthRefs.current.set(entry.monthKey, node);
                      return;
                    }
                    monthRefs.current.delete(entry.monthKey);
                  }}
                  className={`month-sidebar-month${active ? " active" : ""}`}
                  onClick={() => onSelectMonth(entry.monthKey)}
                >
                  <span>{formatMonthLabel(entry.monthKey)}</span>
                  <span>{entry.count}</span>
                </button>
              );
            })}
          </div>
        ))}
      </aside>
      <OverlayScrollbar scrollRef={sidebarRef} getScrollLabel={getScrollLabel} />
    </div>
  );
});

MonthSidebar.displayName = "MonthSidebar";
