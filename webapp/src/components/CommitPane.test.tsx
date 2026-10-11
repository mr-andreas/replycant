import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
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

// A running tailnet, so the pane has a connectivity section to show.
const runningTailnet = {
  running: true,
  status: {
    backendState: "Running",
    tailnetIps: ["100.64.0.2"],
    derpHome: "fra",
    serverPath: "direct",
    serverRelay: "",
    peers: 2,
    peersOnline: 1,
    health: [] as string[],
  },
};

afterEach(() => {
  delete (window as unknown as { replycantDesktop?: unknown }).replycantDesktop;
});

describe("CommitPane", () => {
  // The pane is a single-open accordion. Sync starts open so the sync
  // controls stay reachable without an extra click.
  it("opens Sync by default and keeps the other sections collapsed", () => {
    render(<CommitPane {...buildProps()} />);

    expect(screen.getByRole("button", { name: "Sync" })).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("button", { name: "Commits" })).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByRole("button", { name: "Data management" })).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByRole("button", { name: "Connectivity" })).toBeNull();
  });

  // One open section keeps the collapsed headers visible at the bottom
  // instead of pushing them below a long commit list.
  it("opens one section at a time and collapses it again", () => {
    render(<CommitPane {...buildProps()} />);

    fireEvent.click(screen.getByRole("button", { name: "Commits" }));
    expect(screen.getByRole("button", { name: "Commits" })).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("button", { name: "Sync" })).toHaveAttribute("aria-expanded", "false");

    fireEvent.click(screen.getByRole("button", { name: "Commits" }));
    expect(screen.getByRole("button", { name: "Commits" })).toHaveAttribute("aria-expanded", "false");
  });

  // LAN deployments and the browser build have no tailnet, and an empty
  // Connectivity section would describe a network that is not there.
  it("hides Connectivity when this device is not on a tailnet", () => {
    render(<CommitPane {...buildProps()} />);

    expect(screen.queryByRole("button", { name: "Connectivity" })).toBeNull();
  });

  it("shows Connectivity when this device is on a tailnet", async () => {
    (window as unknown as { replycantDesktop?: unknown }).replycantDesktop = {
      tailnetStatus: vi.fn(async () => runningTailnet),
      onTailnetStatus: vi.fn(() => () => {}),
    };
    render(<CommitPane {...buildProps()} />);

    expect(await screen.findByRole("button", { name: "Connectivity" })).toHaveAttribute(
      "aria-expanded",
      "false",
    );
  });

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

    fireEvent.click(screen.getByRole("button", { name: "Data management" }));
    fireEvent.click(screen.getByRole("button", { name: "Reset & Resync" }));

    expect(props.onResetAndResync).toHaveBeenCalledTimes(1);
  });

  it("hides data management when the database version is unrecoverable", () => {
    const props = buildProps();
    render(<CommitPane {...props} unrecoverableError="Create a new library to continue" />);

    expect(screen.queryByRole("button", { name: "Data management" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Reset & Resync" })).toBeNull();
  });

  it("shows a failed heading when a sync error is set", () => {
    const props = buildProps();
    render(<CommitPane {...props} error="Sync failed: network" />);

    expect(screen.getByText("Sync failed")).toBeInTheDocument();
    expect(screen.queryByText("Ready")).toBeNull();
  });
});
