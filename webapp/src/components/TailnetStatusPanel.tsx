import { useEffect, useState } from "react";

// What the main process reports about the tailnet.
//
// Mirrors TailnetStatus in server/tailnetSidecar.ts. Declared here rather than
// imported because the renderer cannot import from the Electron side, and the
// bridge hands it over as plain JSON.
export interface TailnetStatusReport {
  backendState: string;
  tailnetIps: string[];
  derpHome: string;
  serverPath: string;
  serverRelay: string;
  peers: number;
  peersOnline: number;
  health: string[];
  lastError?: string;
}

export interface TailnetStatusEnvelope {
  running: boolean;
  status?: TailnetStatusReport;
}

interface TailnetBridge {
  tailnetStatus?: () => Promise<unknown>;
  onTailnetStatus?: (listener: (status: unknown) => void) => () => void;
}

// Narrows what the bridge hands over, since it crosses a JSON boundary and a
// mismatch would otherwise render as blank fields claiming the tailnet had lost
// its addresses.
const toEnvelope = (raw: unknown): TailnetStatusEnvelope | null => {
  if (typeof raw !== "object" || raw === null) {
    return null;
  }
  const candidate = raw as Partial<TailnetStatusEnvelope>;
  if (typeof candidate.running !== "boolean") {
    return null;
  }
  return { running: candidate.running, status: candidate.status };
};

// How the path to gitd reads to a user.
//
// The region is what makes "hel" distinct from a direct connection.
const describeServerPath = (path: string, relay: string): string => {
  switch (path) {
    case "direct":
      return "Direct";
    case "relay":
      return relay ? `Relay (${relay})` : "Relay";
    case "offline":
      return "Offline";
    default:
      return "";
  }
};

// Shows how this device is connected to its library's network.
//
// Before this, a device that could not reach the server gave the same
// symptom - a failed sync - whether it was off the tailnet, on the tailnet but
// unable to route, or on the tailnet with the server down. The user's only
// recourse was to re-pair. This panel is what makes those distinguishable.
//
// It renders nothing on LAN deployments and in the browser build, because
// there is no tailnet to describe and a panel claiming a broken connection
// would send the user chasing a problem they do not have.
export const TailnetStatusPanel = () => {
  const [envelope, setEnvelope] = useState<TailnetStatusEnvelope | null>(null);

  useEffect(() => {
    const bridge = (window as unknown as { replycantDesktop?: TailnetBridge }).replycantDesktop;
    if (!bridge?.tailnetStatus) {
      return;
    }

    let active = true;
    void bridge.tailnetStatus().then(
      (raw) => {
        if (active) {
          setEnvelope(toEnvelope(raw));
        }
      },
      () => {
        // A failed query means the main process is not answering, which the
        // app already surfaces elsewhere; claiming a broken tailnet here would
        // be a guess.
      },
    );

    // Subscribing as well as querying, because status changes every few
    // seconds and the panel is expected to stay open.
    const unsubscribe = bridge.onTailnetStatus?.((raw) => setEnvelope(toEnvelope(raw)));
    return () => {
      active = false;
      unsubscribe?.();
    };
  }, []);

  if (!envelope?.running || !envelope.status) {
    return null;
  }

  const status = envelope.status;
  const connected = status.backendState === "Running";

  return (
    <section className="tailnet-status" aria-label="Library network">
      <p className="commit-pane-section-label">Library network</p>
      <p className={`tailnet-status-state${connected ? " connected" : ""}`}>
        {connected ? "Connected" : "Disconnected"}
      </p>
      <dl className="tailnet-status-detail">
        {status.tailnetIps.length > 0 ? (
          <>
            <dt>Address</dt>
            <dd>{status.tailnetIps[0]}</dd>
          </>
        ) : null}
        {status.serverPath ? (
          <>
            <dt>Server path</dt>
            <dd>{describeServerPath(status.serverPath, status.serverRelay)}</dd>
          </>
        ) : null}
        {status.derpHome ? (
          <>
            <dt>Relay region</dt>
            <dd>{status.derpHome}</dd>
          </>
        ) : null}
        <dt>Peers online</dt>
        <dd>
          {status.peersOnline} of {status.peers}
        </dd>
      </dl>
      {status.health.map((warning) => (
        <p key={warning} className="tailnet-status-warning">
          {warning}
        </p>
      ))}
      {status.lastError ? <p className="tailnet-status-warning">{status.lastError}</p> : null}
    </section>
  );
};
