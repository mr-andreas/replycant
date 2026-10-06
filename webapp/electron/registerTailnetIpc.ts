import type { IpcMain } from "electron";
import { TailnetSidecarConfig, TailnetStatus } from "../server/tailnetSidecar";
import { TailnetSupervisor } from "./tailnetSupervisor";

// Shape the renderer sends over IPC. Deliberately not the sidecar config type:
// the state directory is chosen by the main process, because letting the
// renderer name a filesystem path would hand a compromised page an arbitrary
// write target outside the sandbox.
export interface TailnetJoinRequest {
  headscaleAddr: string;
  headscaleServerName?: string;
  gitdControlAddr?: string;
  gitdControlServerName?: string;
  caPem: string;
  clientCertPem: string;
  clientKeyPem: string;
  hostname: string;
}

const requiredFields = [
  "headscaleAddr",
  "caPem",
  "clientCertPem",
  "clientKeyPem",
  "hostname",
] as const;

const readString = (source: Record<string, unknown>, field: string): string | undefined => {
  const value = source[field];
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
};

// Validates the request at the trust boundary.
//
// The renderer is sandboxed and context-isolated, but it renders content the
// deployment owner has not necessarily reviewed, so a malformed or hostile
// payload must fail here rather than reach process spawning.
export const parseJoinRequest = (raw: unknown): TailnetSidecarConfig => {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("tailnet: join request must be an object");
  }
  const source = raw as Record<string, unknown>;

  const missing = requiredFields.filter((field) => readString(source, field) === undefined);
  if (missing.length > 0) {
    throw new Error(`tailnet: join request is missing ${missing.join(", ")}`);
  }

  return {
    headscaleAddr: readString(source, "headscaleAddr")!,
    headscaleServerName: readString(source, "headscaleServerName"),
    // Optional: a deployment whose in-tailnet control relay is turned off has
    // no second path, and the sidecar keeps using the relay.
    gitdControlAddr: readString(source, "gitdControlAddr"),
    gitdControlServerName: readString(source, "gitdControlServerName"),
    caPem: readString(source, "caPem")!,
    clientCertPem: readString(source, "clientCertPem")!,
    clientKeyPem: readString(source, "clientKeyPem")!,
    hostname: readString(source, "hostname")!,
    // Filled in by the caller, which owns the app's data directory.
    stateDir: "",
  };
};

// What the renderer learns about the tailnet.
//
// `running` alone was not enough to explain a failure: a node can be running
// and still unable to reach the server. The rest of the fields are what let the
// app say which of those it is, and are absent while the tailnet is down.
export interface TailnetIpcStatus {
  running: boolean;
  status?: TailnetStatus;
}

// Channel the main process pushes status on.
//
// A push as well as a query because status changes every few seconds and a
// panel the user is looking at must follow it without being reopened.
export const TAILNET_STATUS_EVENT = "tailnet:statusChanged";

// Registers the tailnet IPC once so the production and dev Electron shells stay
// in sync, mirroring registerIdentityKeyIpc.
//
// The renderer drives this because the credentials come from the pairing record
// it holds, and pairing can happen long after the window has opened.
//
// `broadcast` is injected rather than reaching for BrowserWindow here, because
// which windows exist is the shell's concern and a test has no windows at all.
export const registerTailnetIpc = (
  ipcMain: IpcMain,
  deps: {
    supervisor: TailnetSupervisor;
    stateDir: string;
    broadcast?: (channel: string, payload: TailnetIpcStatus) => void;
  },
): void => {
  ipcMain.handle("tailnet:join", async (_event, raw: unknown) => {
    const config = parseJoinRequest(raw);
    await deps.supervisor.start({ ...config, stateDir: deps.stateDir });
  });

  ipcMain.handle("tailnet:leave", async () => {
    await deps.supervisor.stop();
    // Pushed on the way down too, or the panel keeps showing the connection
    // the user just left.
    deps.broadcast?.(TAILNET_STATUS_EVENT, { running: false });
  });

  ipcMain.handle(
    "tailnet:status",
    (): TailnetIpcStatus => ({
      running: deps.supervisor.isRunning(),
      status: deps.supervisor.getStatus(),
    }),
  );

  if (deps.broadcast) {
    deps.supervisor.onStatus((status) => {
      deps.broadcast?.(TAILNET_STATUS_EVENT, { running: true, status });
    });
  }
};
