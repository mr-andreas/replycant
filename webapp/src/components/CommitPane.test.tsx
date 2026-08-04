import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { CommitPane } from "./CommitPane";

const buildProps = () => ({
  commits: [],
  timelineItemCount: 1234,
  syncedCommitHash: null,
  periodicSyncUserEnabled: true,
  syncIntervalMs: 2000,
  isOffHead: false,
  rewindActionBusy: null as "rewind" | "forward" | null,
  onSelectCommit: vi.fn(),
  onTogglePeriodicSync: vi.fn(),
  onChangeSyncInterval: vi.fn(),
  syncing: false,
  error: null,
  lastSyncAt: null,
  requiresHardResetPermission: false,
  cloneProgress: null,
  onSyncNow: vi.fn(),
  onResetToRemote: vi.fn(),
  onResetAndResync: vi.fn(),
});

describe("CommitPane", () => {
  it("renders the formatted timeline media count", () => {
    render(<CommitPane {...buildProps()} />);

    expect(screen.getByText("1,234 media in timeline")).toBeInTheDocument();
  });

  it("calls toggle and interval handlers from StatusBanner controls", () => {
    const props = buildProps();
    render(<CommitPane {...props} />);

    fireEvent.click(screen.getByRole("checkbox", { name: "Auto" }));
    fireEvent.change(screen.getByRole("combobox"), {
      target: { value: "5000" },
    });

    expect(props.onTogglePeriodicSync).toHaveBeenCalledWith(false);
    expect(props.onChangeSyncInterval).toHaveBeenCalledWith(5000);
  });

  it("auto-sync checkbox is never disabled when on HEAD", () => {
    const props = buildProps();
    props.periodicSyncUserEnabled = false;
    render(<CommitPane {...props} />);

    const checkbox = screen.getByRole("checkbox", { name: "Auto" });
    expect(checkbox).not.toBeDisabled();
  });

  it("disables controls and hides sync button when off HEAD", () => {
    const props = buildProps();
    props.isOffHead = true;
    render(<CommitPane {...props} />);

    expect(screen.getByRole("checkbox", { name: "Auto" })).toBeDisabled();
    expect(screen.getByRole("combobox")).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Sync now" })).toBeNull();
    expect(screen.getByText("Return to head to sync")).toBeInTheDocument();
  });

  it("renders reset and resync action and calls handler on click", () => {
    const props = buildProps();
    render(<CommitPane {...props} />);

    fireEvent.click(screen.getByRole("button", { name: "Reset & Resync" }));

    expect(props.onResetAndResync).toHaveBeenCalledTimes(1);
  });
});
