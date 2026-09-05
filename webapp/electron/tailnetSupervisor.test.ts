import { describe, expect, it, vi } from "vitest";
import { createTailnetSupervisor, resolveSidecarPath } from "./tailnetSupervisor";
import { TailnetSidecar, TailnetSidecarConfig } from "../server/tailnetSidecar";

const config: TailnetSidecarConfig = {
  headscaleAddr: "abc.tunnel.replycant.com:443",
  caPem: "ca",
  clientCertPem: "cert",
  clientKeyPem: "key",
  stateDir: "/tmp/replycant/tsnet",
  hostname: "desktop",
};

// Builds a fake sidecar handle so the supervisor's lifecycle can be tested
// without spawning anything.
const makeSidecar = (socksAddr: string): TailnetSidecar & { stop: ReturnType<typeof vi.fn> } => ({
  proxy: { socksAddr, socksUsername: "tsnet", socksPassword: "secret" },
  tailnetIps: ["100.64.0.2"],
  stop: vi.fn(async () => {}),
});

describe("resolveSidecarPath", () => {
  // electron-builder puts extraResources under process.resourcesPath, and this
  // is the first native binary the desktop app ships, so getting the packaged
  // layout wrong would break every release while working in development.
  it("resolves inside the resources directory when packaged", () => {
    const path = resolveSidecarPath({
      resourcesPath: "/Applications/Replycant.app/Contents/Resources",
      projectRoot: "/src/webapp",
      packaged: true,
    });
    expect(path).toContain("/Applications/Replycant.app/Contents/Resources");
    expect(path).toContain("replycant-tsnet");
    expect(path).not.toContain("/src/webapp");
  });

  // Development builds have no resources directory, so the locally built
  // binary in the source tree is used instead.
  it("resolves inside the source tree when unpackaged", () => {
    const path = resolveSidecarPath({
      resourcesPath: "/unused",
      projectRoot: "/src/webapp",
      packaged: false,
    });
    expect(path).toContain("/src/webapp");
    expect(path).toContain("sidecar");
  });

  // Windows spawn will not find an extensionless file, and electron-builder
  // does not rename resources per platform.
  it("uses the platform's executable name", () => {
    const path = resolveSidecarPath({
      resourcesPath: "/res",
      projectRoot: "/src",
      packaged: true,
    });
    const expected = process.platform === "win32" ? "replycant-tsnet.exe" : "replycant-tsnet";
    expect(path.endsWith(expected)).toBe(true);
  });
});

describe("createTailnetSupervisor", () => {
  // The HTTP server is already running when the tailnet comes up, and reads the
  // proxy on every agent acquire. Before a start there is nothing to dial.
  it("has no proxy before the tailnet is started", () => {
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => makeSidecar("127.0.0.1:1"),
    });
    expect(supervisor.getProxy()).toBeUndefined();
    expect(supervisor.isRunning()).toBe(false);
  });

  // Once the renderer supplies the pairing credentials, the proxy has to become
  // visible to the already-running server.
  it("exposes the proxy after starting", async () => {
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => makeSidecar("127.0.0.1:41234"),
    });

    const proxy = await supervisor.start(config);

    expect(proxy.socksAddr).toBe("127.0.0.1:41234");
    expect(supervisor.getProxy()?.socksAddr).toBe("127.0.0.1:41234");
    expect(supervisor.isRunning()).toBe(true);
  });

  // A user can re-pair a device, and the old node would then hold a credential
  // the deployment has revoked. Reconfiguring must replace the node rather than
  // leaving two running.
  it("replaces the running node when reconfigured", async () => {
    const first = makeSidecar("127.0.0.1:41111");
    const second = makeSidecar("127.0.0.1:42222");
    const sidecars = [first, second];
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => sidecars.shift()!,
    });

    await supervisor.start(config);
    await supervisor.start({ ...config, hostname: "desktop-2" });

    expect(first.stop).toHaveBeenCalledTimes(1);
    expect(supervisor.getProxy()?.socksAddr).toBe("127.0.0.1:42222");
  });

  // Two overlapping starts would each spawn a sidecar, and one would be leaked
  // holding the tailnet node and the loopback ports the other needs.
  it("serialises overlapping starts", async () => {
    let concurrent = 0;
    let maxConcurrent = 0;
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => {
        concurrent += 1;
        maxConcurrent = Math.max(maxConcurrent, concurrent);
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
        concurrent -= 1;
        return makeSidecar("127.0.0.1:41234");
      },
    });

    await Promise.all([supervisor.start(config), supervisor.start(config), supervisor.start(config)]);

    expect(maxConcurrent).toBe(1);
  });

  // The tailnet only exists while the sidecar runs, so app shutdown has to
  // terminate it and stop advertising a proxy nothing is listening on.
  it("clears the proxy on stop", async () => {
    const sidecar = makeSidecar("127.0.0.1:41234");
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => sidecar,
    });

    await supervisor.start(config);
    await supervisor.stop();

    expect(sidecar.stop).toHaveBeenCalledTimes(1);
    expect(supervisor.getProxy()).toBeUndefined();
    expect(supervisor.isRunning()).toBe(false);
  });

  // before-quit can fire more than once, so stopping when nothing is running
  // must be harmless rather than throwing during shutdown.
  it("tolerates stopping when nothing is running", async () => {
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => makeSidecar("127.0.0.1:41234"),
    });
    await expect(supervisor.stop()).resolves.toBeUndefined();
  });

  // A failed start must leave the supervisor advertising no proxy. Reporting a
  // stale one would send every request to a port nothing is listening on.
  it("advertises no proxy when the start fails", async () => {
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => {
        throw new Error("control plane unreachable");
      },
    });

    await expect(supervisor.start(config)).rejects.toThrow(/control plane unreachable/);
    expect(supervisor.getProxy()).toBeUndefined();
    expect(supervisor.isRunning()).toBe(false);
  });

  // A start that fails must not leave the previous node running either: its
  // credential may be the one that was just revoked.
  it("stops the previous node even when the replacement fails", async () => {
    const first = makeSidecar("127.0.0.1:41111");
    let attempt = 0;
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      startFn: async () => {
        attempt += 1;
        if (attempt === 1) {
          return first;
        }
        throw new Error("control plane unreachable");
      },
    });

    await supervisor.start(config);
    await expect(supervisor.start(config)).rejects.toThrow();

    expect(first.stop).toHaveBeenCalledTimes(1);
    expect(supervisor.getProxy()).toBeUndefined();
  });

  // A sidecar that will not shut down cleanly must not block the app from
  // quitting or from starting a replacement.
  it("recovers when the sidecar fails to stop", async () => {
    const stubborn: TailnetSidecar = {
      proxy: { socksAddr: "127.0.0.1:41111", socksUsername: "tsnet", socksPassword: "s" },
      tailnetIps: [],
      stop: vi.fn(async () => {
        throw new Error("refused to exit");
      }),
    };
    const logged: string[] = [];
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant-tsnet",
      logf: (message) => logged.push(message),
      startFn: async () => stubborn,
    });

    await supervisor.start(config);
    await expect(supervisor.stop()).resolves.toBeUndefined();

    expect(supervisor.getProxy()).toBeUndefined();
    expect(logged.some((line) => line.includes("failed to stop"))).toBe(true);
  });

  // The supervisor passes the binary path through, so a packaging mistake shows
  // up as a spawn failure naming the path rather than something more obscure.
  it("starts the configured binary", async () => {
    const startFn = vi.fn(async () => makeSidecar("127.0.0.1:41234"));
    const supervisor = createTailnetSupervisor({
      binaryPath: "/opt/replycant/replycant-tsnet",
      startFn,
    });

    await supervisor.start(config);

    expect(startFn.mock.calls[0]?.[0].binaryPath).toBe("/opt/replycant/replycant-tsnet");
    expect(startFn.mock.calls[0]?.[0].config).toBe(config);
  });
});
