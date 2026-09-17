import { describe, expect, it, vi } from "vitest";
import { parseJoinRequest, registerTailnetIpc, TAILNET_STATUS_EVENT } from "./registerTailnetIpc";
import { TailnetSupervisor } from "./tailnetSupervisor";
import { TailnetStatus } from "../server/tailnetSidecar";

const runningStatus: TailnetStatus = {
  backendState: "Running",
  tailnetIps: ["100.64.0.2"],
  derpHome: "fra",
  controlRoute: "tailnet",
  serverPath: "direct",
  serverRelay: "",
  peers: 2,
  peersOnline: 1,
  health: [],
};

const validRequest = {
  headscaleAddr: "abc.tunnel.replycant.com:443",
  caPem: "-----BEGIN CERTIFICATE-----ca",
  clientCertPem: "-----BEGIN CERTIFICATE-----leaf",
  clientKeyPem: "-----BEGIN PRIVATE KEY-----key",
  hostname: "desktop",
};

// Collects the handlers a registration installs so they can be invoked without
// an Electron process.
const fakeIpcMain = () => {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>();
  return {
    handlers,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ipcMain: { handle: (channel: string, handler: any) => handlers.set(channel, handler) } as any,
    invoke: (channel: string, ...args: unknown[]) => {
      const handler = handlers.get(channel);
      if (!handler) {
        throw new Error(`no handler for ${channel}`);
      }
      return handler({}, ...args);
    },
  };
};

const fakeSupervisor = (): TailnetSupervisor & {
  start: ReturnType<typeof vi.fn>;
  stop: ReturnType<typeof vi.fn>;
  publish: (status: TailnetStatus) => void;
} => {
  let running = false;
  const start = vi.fn(async () => {
    running = true;
    return { socksAddr: "127.0.0.1:41234", socksUsername: "tsnet", socksPassword: "s" };
  });
  const stop = vi.fn(async () => {
    running = false;
  });
  const listeners = new Set<(status: TailnetStatus) => void>();
  return {
    start,
    stop,
    getProxy: () =>
      running ? { socksAddr: "127.0.0.1:41234", socksUsername: "tsnet", socksPassword: "s" } : undefined,
    isRunning: () => running,
    getStatus: () => (running ? runningStatus : undefined),
    onStatus: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    publish: (status: TailnetStatus) => {
      for (const listener of listeners) {
        listener(status);
      }
    },
  };
};

describe("parseJoinRequest", () => {
  it("accepts a complete request", () => {
    const config = parseJoinRequest(validRequest);
    expect(config.headscaleAddr).toBe("abc.tunnel.replycant.com:443");
    expect(config.hostname).toBe("desktop");
  });

  // Naming the field that is missing keeps a pairing bug diagnosable from a
  // user's log instead of requiring a debugger.
  it.each(["headscaleAddr", "caPem", "clientCertPem", "clientKeyPem", "hostname"])(
    "rejects a request missing %s",
    (field) => {
      const incomplete = { ...validRequest } as Record<string, unknown>;
      delete incomplete[field];
      expect(() => parseJoinRequest(incomplete)).toThrow(new RegExp(field));
    },
  );

  // A blank string would otherwise pass a presence check and fail much later,
  // inside the sidecar, as a confusing tsnet error.
  it("treats a blank required field as missing", () => {
    expect(() => parseJoinRequest({ ...validRequest, hostname: "   " })).toThrow(/hostname/);
  });

  // Manual-exposure deployments reach headscale under their own DNS name, and
  // registration can reuse an existing node, so these two are genuinely
  // optional rather than merely unset in tests.
  it("leaves the optional fields unset when absent", () => {
    const config = parseJoinRequest(validRequest);
    expect(config.headscaleServerName).toBeUndefined();
    expect(config.preauthKey).toBeUndefined();
  });

  it("carries the optional fields when present", () => {
    const config = parseJoinRequest({
      ...validRequest,
      headscaleServerName: "headscale.example.com",
      preauthKey: "nodekey-test",
    });
    expect(config.headscaleServerName).toBe("headscale.example.com");
    expect(config.preauthKey).toBe("nodekey-test");
  });

  // The renderer sends this over IPC, so anything at all can arrive. Failing on
  // a non-object keeps the error at the boundary rather than as a property
  // access on undefined deeper in.
  it.each([null, undefined, "string", 42, []])("rejects the non-object %s", (raw) => {
    expect(() => parseJoinRequest(raw as unknown)).toThrow();
  });

  // A number or object in a string field must not reach spawn arguments.
  it("rejects a non-string field", () => {
    expect(() => parseJoinRequest({ ...validRequest, headscaleAddr: 443 })).toThrow(
      /headscaleAddr/,
    );
  });
});

describe("registerTailnetIpc", () => {
  it("registers the join, leave, and status channels", () => {
    const { ipcMain, handlers } = fakeIpcMain();
    registerTailnetIpc(ipcMain, { supervisor: fakeSupervisor(), stateDir: "/data/tsnet" });
    expect([...handlers.keys()].sort()).toEqual(["tailnet:join", "tailnet:leave", "tailnet:status"]);
  });

  // Letting the renderer name a filesystem path would hand a compromised page
  // an arbitrary write target, so the main process overrides whatever arrives.
  it("uses the main process state directory and ignores the renderer's", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const supervisor = fakeSupervisor();
    registerTailnetIpc(ipcMain, { supervisor, stateDir: "/data/tsnet" });

    await invoke("tailnet:join", { ...validRequest, stateDir: "/etc" });

    expect(supervisor.start.mock.calls[0]?.[0].stateDir).toBe("/data/tsnet");
  });

  it("starts the tailnet on join", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const supervisor = fakeSupervisor();
    registerTailnetIpc(ipcMain, { supervisor, stateDir: "/data/tsnet" });

    await invoke("tailnet:join", validRequest);

    expect(supervisor.start).toHaveBeenCalledTimes(1);
    expect(supervisor.start.mock.calls[0]?.[0].headscaleAddr).toBe(
      "abc.tunnel.replycant.com:443",
    );
  });

  it("stops the tailnet on leave", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const supervisor = fakeSupervisor();
    registerTailnetIpc(ipcMain, { supervisor, stateDir: "/data/tsnet" });

    await invoke("tailnet:join", validRequest);
    await invoke("tailnet:leave");

    expect(supervisor.stop).toHaveBeenCalledTimes(1);
  });

  // The renderer needs this to decide whether onboarding is still required
  // after a restart, since the node's state survives in the state directory.
  it("reports whether the tailnet is up", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    registerTailnetIpc(ipcMain, { supervisor: fakeSupervisor(), stateDir: "/data/tsnet" });

    expect(await invoke("tailnet:status")).toEqual({ running: false, status: undefined });
    await invoke("tailnet:join", validRequest);
    expect(await invoke("tailnet:status")).toEqual({ running: true, status: runningStatus });
  });

  // "running" alone cannot explain a failure: a node can be up and still
  // unable to reach the server. The panel needs the detail, not just the flag.
  it("reports the connection detail alongside the flag", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    registerTailnetIpc(ipcMain, { supervisor: fakeSupervisor(), stateDir: "/data/tsnet" });

    await invoke("tailnet:join", validRequest);
    const reported = (await invoke("tailnet:status")) as { status?: TailnetStatus };

    expect(reported.status?.controlRoute).toBe("tailnet");
    expect(reported.status?.derpHome).toBe("fra");
  });

  // Status changes every few seconds, so a panel the user is looking at has to
  // follow it rather than showing whatever was true when it opened.
  it("pushes status to the renderer as it arrives", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const supervisor = fakeSupervisor();
    const sent: Array<{ channel: string; payload: unknown }> = [];
    registerTailnetIpc(ipcMain, {
      supervisor,
      stateDir: "/data/tsnet",
      broadcast: (channel, payload) => sent.push({ channel, payload }),
    });

    await invoke("tailnet:join", validRequest);
    supervisor.publish(runningStatus);

    expect(sent).toEqual([
      { channel: TAILNET_STATUS_EVENT, payload: { running: true, status: runningStatus } },
    ]);
  });

  // Otherwise the panel keeps showing the connection the user just left.
  it("pushes a stopped status on leave", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const sent: Array<{ channel: string; payload: unknown }> = [];
    registerTailnetIpc(ipcMain, {
      supervisor: fakeSupervisor(),
      stateDir: "/data/tsnet",
      broadcast: (channel, payload) => sent.push({ channel, payload }),
    });

    await invoke("tailnet:join", validRequest);
    await invoke("tailnet:leave");

    expect(sent.at(-1)).toEqual({
      channel: TAILNET_STATUS_EVENT,
      payload: { running: false },
    });
  });

  // A rejected join must surface to the renderer so onboarding can show the
  // failure, rather than silently leaving the app off the tailnet.
  it("propagates a malformed join to the caller", async () => {
    const { ipcMain, invoke } = fakeIpcMain();
    const supervisor = fakeSupervisor();
    registerTailnetIpc(ipcMain, { supervisor, stateDir: "/data/tsnet" });

    await expect(invoke("tailnet:join", { hostname: "desktop" })).rejects.toThrow(/missing/);
    expect(supervisor.start).not.toHaveBeenCalled();
  });
});
