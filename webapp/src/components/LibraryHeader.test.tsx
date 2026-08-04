import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { LibraryHeader } from "./LibraryHeader";

describe("LibraryHeader", () => {
  it("renders brand assets without the view switcher while only timeline ships", () => {
    const { container } = render(
      <LibraryHeader
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
      />,
    );

    expect(screen.getByText("Replycant")).toBeInTheDocument();
    expect(container.querySelector(".brand-logo")).toBeTruthy();
    expect(screen.queryByRole("tab")).toBeNull();
    expect(container.querySelector(".view-switcher")).toBeNull();
  });

  it("invokes callbacks for settings and month toggles", () => {
    const onToggleCommitPane = vi.fn();
    const onToggleMonthSidebar = vi.fn();
    render(
      <LibraryHeader
        activeView="albums"
        onSelectView={vi.fn()}
        commitPaneOpen
        onToggleCommitPane={onToggleCommitPane}
        showMonthToggle
        showMonthSidebar
        onToggleMonthSidebar={onToggleMonthSidebar}
      />,
    );

    fireEvent.click(screen.getByLabelText("Hide settings and commits"));
    fireEvent.click(screen.getByLabelText("Hide months"));

    expect(onToggleCommitPane).toHaveBeenCalled();
    expect(onToggleMonthSidebar).toHaveBeenCalled();
  });
});
