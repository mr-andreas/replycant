import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TailnetStatusPanel } from "./TailnetStatusPanel";

// A tailnet that is fully up, with a direct path to gitd.
const connected = {
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

// Installs the desktop bridge the panel reads from.
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

describe("TailnetStatusPanel", () => {
  // The panel exists so a user can tell "this device is not on the tailnet"
  // from "this device is on the tailnet but the server is down". Both used to
  // look like a failed sync with no way to tell them apart.
  it("shows the tailnet as connected with its address and path to the server", async () => {
    installBridge(connected);
    render(<TailnetStatusPanel />);

    expect(await screen.findByText("Connected")).toBeInTheDocument();
    expect(screen.getByText("100.64.0.2")).toBeInTheDocument();
    expect(screen.getByText("Direct")).toBeInTheDocument();
    expect(screen.getByText("fra")).toBeInTheDocument();
  });

  // Empty CurAddr with a region is Tailscale's DERP hop to gitd. Showing
  // the region is what keeps "hel" distinct from a direct connection.
  it("names the DERP region when gitd is reached through a relay", async () => {
    installBridge({
      running: true,
      status: { ...connected.status, serverPath: "relay", serverRelay: "hel" },
    });
    render(<TailnetStatusPanel />);

    expect(await screen.findByText("Relay (hel)")).toBeInTheDocument();
  });

  // A node that is Running but unhealthy would otherwise look like a healthy
  // tailnet and a broken server.
  it("surfaces tailscale's health warnings", async () => {
    installBridge({
      running: true,
      status: { ...connected.status, health: ["DERP region fra is unreachable"] },
    });
    render(<TailnetStatusPanel />);

    expect(await screen.findByText(/DERP region fra is unreachable/)).toBeInTheDocument();
  });

  // A node that is not answering is its own state: freezing on the last good
  // reading would claim a connection the device does not have.
  it("reports a node that stopped answering", async () => {
    installBridge({
      running: true,
      status: { ...connected.status, backendState: "Unknown", lastError: "node is not answering" },
    });
    render(<TailnetStatusPanel />);

    expect(await screen.findByText(/node is not answering/)).toBeInTheDocument();
  });

  // Status arrives every few seconds, and a panel that only read once would go
  // stale while the user was looking at it.
  it("follows status pushed after it rendered", async () => {
    const { push } = installBridge(connected);
    render(<TailnetStatusPanel />);
    await screen.findByText("Connected");

    push({ running: true, status: { ...connected.status, backendState: "Stopped" } });

    await waitFor(() => expect(screen.getByText("Disconnected")).toBeInTheDocument());
  });

  // LAN deployments have no tailnet at all, and a panel claiming a broken
  // connection would send the user chasing a problem they do not have.
  it("renders nothing when this device is not on a tailnet", async () => {
    installBridge({ running: false });
    const { container } = render(<TailnetStatusPanel />);

    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  // The browser build has no desktop bridge, and asking for status there must
  // not throw during render.
  it("renders nothing without a desktop bridge", () => {
    const { container } = render(<TailnetStatusPanel />);
    expect(container).toBeEmptyDOMElement();
  });
});
