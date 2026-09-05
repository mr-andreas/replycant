import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { startTailnetSidecar, TailnetSidecarConfig } from "./tailnetSidecar";

const config: TailnetSidecarConfig = {
  headscaleAddr: "abc.tunnel.replycant.com:443",
  headscaleServerName: "abc.tunnel.replycant.com",
  caPem: "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----",
  clientCertPem: "-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----",
  clientKeyPem: "-----BEGIN EC PRIVATE KEY-----\nkey\n-----END EC PRIVATE KEY-----",
  preauthKey: "hskey-auth-example",
  stateDir: "/tmp/replycant/tsnet",
  hostname: "desktop",
};

// Stands in for the Go sidecar so the supervisor's contract - what it writes,
// what it waits for, how it tears down - can be tested without a real binary
// or a real tailnet.
class FakeSidecarProcess extends EventEmitter {
  public stdin = new PassThrough();
  public stdout = new PassThrough();
  public stderr = new PassThrough();
  public exitCode: number | null = null;
  public signalCode: string | null = null;
  public kill = vi.fn((signal?: NodeJS.Signals | number) => {
    this.signalCode = typeof signal === "string" ? signal : "SIGTERM";
    // A well-behaved child exits on SIGTERM; tests that need otherwise
    // override this.
    setImmediate(() => this.emit("exit", null, this.signalCode));
    return true;
  });

  // Emits the readiness line the supervisor is waiting for.
  public announceReady(overrides: Record<string, unknown> = {}) {
    this.stdout.write(
      `${JSON.stringify({
        socks_addr: "127.0.0.1:41234",
        socks_username: "tsnet",
        socks_password: "deadbeef",
        tailnet_ips: ["100.64.0.2"],
        control_url: "http://127.0.0.1:41233",
        ...overrides,
      })}\n`,
    );
  }

  // Captures everything written to stdin, which is how the config is
  // delivered.
  public async readStdin(): Promise<string> {
    const chunks: Buffer[] = [];
    for await (const chunk of this.stdin) {
      chunks.push(Buffer.from(chunk));
    }
    return Buffer.concat(chunks).toString("utf8");
  }
}

const makeSpawn = (child: FakeSidecarProcess) => {
  const spawnFn = vi.fn(() => child as never);
  return spawnFn as unknown as StartSpawn;
};

type StartSpawn = Parameters<typeof startTailnetSidecar>[0]["spawnFn"];

describe("startTailnetSidecar", () => {
  // The whole point: resolve with SOCKS5 details the agent pool can dial, and
  // only once the tailnet is actually up.
  it("returns the SOCKS5 proxy details once the sidecar is ready", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn: makeSpawn(child),
    });

    child.announceReady();
    const sidecar = await starting;

    expect(sidecar.proxy).toEqual({
      socksAddr: "127.0.0.1:41234",
      socksUsername: "tsnet",
      socksPassword: "deadbeef",
    });
    expect(sidecar.tailnetIps).toEqual(["100.64.0.2"]);
    await sidecar.stop();
  });

  // The config contains the device's private key. Arguments are visible in the
  // process list on every platform the desktop app ships to, so it must travel
  // on stdin instead.
  it("passes the configuration on stdin, not as arguments", async () => {
    const child = new FakeSidecarProcess();
    const spawnFn = makeSpawn(child);
    const stdinRead = child.readStdin();

    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn,
    });
    child.announceReady();
    const sidecar = await starting;

    const spawnCall = (spawnFn as unknown as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(spawnCall?.[1]).toEqual([]);

    const written = JSON.parse(await stdinRead) as Record<string, string>;
    expect(written.client_key_pem).toBe(config.clientKeyPem);
    expect(written.headscale_addr).toBe(config.headscaleAddr);
    expect(written.state_dir).toBe(config.stateDir);
    expect(written.hostname).toBe(config.hostname);

    await sidecar.stop();
  });

  // The sidecar reads its config to EOF, so leaving stdin open would hang it
  // before it ever tried to join.
  it("closes stdin so the sidecar can finish reading its configuration", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn: makeSpawn(child),
    });
    child.announceReady();
    const sidecar = await starting;

    expect(child.stdin.writableEnded).toBe(true);
    await sidecar.stop();
  });

  // A bad credential or unreachable control plane makes the sidecar exit. That
  // has to reject immediately rather than waiting out the ready timeout, or
  // the app appears to hang for two minutes on a failure it already knows
  // about.
  it("fails fast when the sidecar exits before joining", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn: makeSpawn(child),
    });

    child.emit("exit", 1, null);

    await expect(starting).rejects.toThrow(/exited before joining/);
  });

  // A missing binary is the packaging failure mode, and it must be reported as
  // such rather than as a timeout.
  it("reports a spawn failure", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/does/not/exist",
      config,
      spawnFn: makeSpawn(child),
    });

    child.emit("error", new Error("ENOENT"));

    await expect(starting).rejects.toThrow(/could not be started/);
  });

  // Without a bound wait, a control plane that accepts the connection but
  // never answers would leave the app stuck on a splash screen with no error.
  it("gives up if the tailnet never comes up", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      readyTimeoutMs: 20,
      spawnFn: makeSpawn(child),
    });

    await expect(starting).rejects.toThrow(/did not join the tailnet/);
  });

  // A failed start must not leave the process running: it would hold the
  // tailnet node and the loopback ports a retry needs.
  it("stops the process when startup fails", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      readyTimeoutMs: 20,
      spawnFn: makeSpawn(child),
    });

    await expect(starting).rejects.toThrow();
    expect(child.kill).toHaveBeenCalled();
  });

  // A readiness line without usable SOCKS5 details would otherwise be accepted
  // and every later request would fail with no indication of the cause.
  it("ignores a readiness line that carries no usable proxy", async () => {
    const child = new FakeSidecarProcess();
    const logged: string[] = [];
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      readyTimeoutMs: 60,
      logf: (message) => logged.push(message),
      spawnFn: makeSpawn(child),
    });

    child.stdout.write(`${JSON.stringify({ socks_addr: "" })}\n`);

    await expect(starting).rejects.toThrow(/did not join the tailnet/);
    expect(logged.some((line) => line.includes("unexpected stdout"))).toBe(true);
  });

  // The sidecar logs to stderr on purpose, so stdout stays parseable. Those
  // logs are the only diagnostics for a failed join and must be surfaced.
  it("forwards sidecar logs to the caller", async () => {
    const child = new FakeSidecarProcess();
    const logged: string[] = [];
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      logf: (message) => logged.push(message),
      spawnFn: makeSpawn(child),
    });

    child.stderr.write("control plane abc.tunnel.replycant.com fronted at 127.0.0.1:41233\n");
    child.announceReady();
    const sidecar = await starting;

    expect(logged.some((line) => line.includes("fronted at 127.0.0.1:41233"))).toBe(true);
    await sidecar.stop();
  });

  // The tailnet only exists while the sidecar runs, so app shutdown has to
  // terminate it rather than leave an orphan holding the node.
  it("terminates the sidecar on stop", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn: makeSpawn(child),
    });
    child.announceReady();
    const sidecar = await starting;

    await sidecar.stop();

    expect(child.kill).toHaveBeenCalledWith("SIGTERM");
  });

  // Electron calls before-quit more than once in some shutdown paths, so stop
  // has to be safe to repeat.
  it("tolerates being stopped twice", async () => {
    const child = new FakeSidecarProcess();
    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config,
      spawnFn: makeSpawn(child),
    });
    child.announceReady();
    const sidecar = await starting;

    await sidecar.stop();
    child.exitCode = 0;
    await sidecar.stop();

    expect(child.kill).toHaveBeenCalledTimes(1);
  });

  // A pre-auth key is single-use, so a rejoining device has none. Requiring it
  // would make every restart after the first fail.
  it("starts without a pre-auth key", async () => {
    const child = new FakeSidecarProcess();
    const stdinRead = child.readStdin();
    const { preauthKey: _omitted, ...withoutKey } = config;

    const starting = startTailnetSidecar({
      binaryPath: "/opt/replycant/replycant-tsnet",
      config: withoutKey as TailnetSidecarConfig,
      spawnFn: makeSpawn(child),
    });
    child.announceReady();
    const sidecar = await starting;

    const written = JSON.parse(await stdinRead) as Record<string, string>;
    expect(written.preauth_key).toBe("");
    await sidecar.stop();
  });
});
