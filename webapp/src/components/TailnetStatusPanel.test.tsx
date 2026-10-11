import { render, renderHook, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TailnetStatusPanel, TailnetStatusReport, useTailnetStatus } from "./TailnetStatusPanel";

// A tailnet that is fully up, with a direct path to gitd.
const connected: TailnetStatusReport = {
  backendState: "Running",
  tailnetIps: ["100.64.0.2"],
  derpHome: "fra",
  serverPath: "direct",
  serverRelay: "",
  peers: 2,
  peersOnline: 1,
  health: [],
};

const connectedEnvelope = { running: true, status: connected };

// Installs the desktop bridge the hook reads from.
const installBridge = (initial: unknown) => {
  const listeners: Array<(status: unknown) => void> = [];
  const bridge = {
    tailnetStatus: vi.fn(async () => initial),
    onTailnetStatus: vi.fn((listener: (status: unknown) => void) => {
      listeners.push(listener);
      return () => {};
    }),
  };
  (window as unknown as { replycantDesktop?: unknown }).replycantDesktop = bridge;
  return { bridge, push: (status: unknown) => listeners.forEach((l) => l(status)) };
};

afterEach(() => {
  delete (window as unknown as { replycantDesktop?: unknown }).replycantDesktop;
});

describe("useTailnetStatus", () => {
  // Status arrives every few seconds, and a reading that only happened once
  // would go stale while the user was looking at the pane.
  it("follows status pushed after it subscribed", async () => {
    const { push } = installBridge(connectedEnvelope);
    const { result } = renderHook(() => useTailnetStatus());

    await waitFor(() => expect(result.current?.backendState).toBe("Running"));

    push({ running: true, status: { ...connected, backendState: "Stopped" } });

    await waitFor(() => expect(result.current?.backendState).toBe("Stopped"));
  });

  // LAN deployments have no tailnet at all, and a section claiming a broken
  // connection would send the user chasing a problem they do not have.
  it("returns null when this device is not on a tailnet", async () => {
    const { bridge } = installBridge({ running: false });
    const { result } = renderHook(() => useTailnetStatus());

    await waitFor(() => expect(bridge.tailnetStatus).toHaveBeenCalled());
    expect(result.current).toBeNull();
  });

  // The browser build has no desktop bridge, and asking for status there must
  // not throw during render.
  it("returns null without a desktop bridge", () => {
    const { result } = renderHook(() => useTailnetStatus());
    expect(result.current).toBeNull();
  });
});

describe("TailnetStatusPanel", () => {
  // The panel exists so a user can tell "this device is not on the tailnet"
  // from "this device is on the tailnet but the server is down". Both used to
  // look like a failed sync with no way to tell them apart.
  it("shows the tailnet as connected with its address and path to the server", () => {
    render(<TailnetStatusPanel status={connected} />);

    expect(screen.getByText("Connected")).toBeInTheDocument();
    expect(screen.getByText("100.64.0.2")).toBeInTheDocument();
    expect(screen.getByText("Direct")).toBeInTheDocument();
    expect(screen.getByText("fra")).toBeInTheDocument();
  });

  // Empty CurAddr with a region is Tailscale's DERP hop to gitd. Showing
  // the region is what keeps "hel" distinct from a direct connection.
  it("names the DERP region when gitd is reached through a relay", () => {
    render(
      <TailnetStatusPanel status={{ ...connected, serverPath: "relay", serverRelay: "hel" }} />,
    );

    expect(screen.getByText("Relay (hel)")).toBeInTheDocument();
  });

  // A node that is Running but unhealthy would otherwise look like a healthy
  // tailnet and a broken server.
  it("surfaces tailscale's health warnings", () => {
    render(
      <TailnetStatusPanel status={{ ...connected, health: ["DERP region fra is unreachable"] }} />,
    );

    expect(screen.getByText(/DERP region fra is unreachable/)).toBeInTheDocument();
  });

  // A node that is not answering is its own state: freezing on the last good
  // reading would claim a connection the device does not have.
  it("reports a node that stopped answering", () => {
    render(
      <TailnetStatusPanel
        status={{ ...connected, backendState: "Unknown", lastError: "node is not answering" }}
      />,
    );

    expect(screen.getByText(/node is not answering/)).toBeInTheDocument();
  });
});
