import type { IpcMain } from "electron";
import { TailnetSidecarConfig } from "../server/tailnetSidecar";
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
  preauthKey?: string;
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
    preauthKey: readString(source, "preauthKey"),
    hostname: readString(source, "hostname")!,
    // Filled in by the caller, which owns the app's data directory.
    stateDir: "",
  };
};

export interface TailnetIpcStatus {
  running: boolean;
}

// Registers the tailnet IPC once so the production and dev Electron shells stay
// in sync, mirroring registerIdentityKeyIpc.
//
// The renderer drives this because the credentials come from the pairing record
// it holds, and pairing can happen long after the window has opened.
export const registerTailnetIpc = (
  ipcMain: IpcMain,
  deps: { supervisor: TailnetSupervisor; stateDir: string },
): void => {
  ipcMain.handle("tailnet:join", async (_event, raw: unknown) => {
    const config = parseJoinRequest(raw);
    await deps.supervisor.start({ ...config, stateDir: deps.stateDir });
  });

  ipcMain.handle("tailnet:leave", async () => {
    await deps.supervisor.stop();
  });

  ipcMain.handle(
    "tailnet:status",
    (): TailnetIpcStatus => ({ running: deps.supervisor.isRunning() }),
  );
};
