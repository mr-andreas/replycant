import { spawn, ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { TailnetProxy } from "./proxy";

// What the sidecar needs in order to join the tailnet on this device's behalf.
//
// Every field except stateDir comes from the pairing record the device opened
// during onboarding. It is passed on stdin rather than as arguments because it
// contains the device's private key, and arguments are visible in the process
// list on every platform the desktop app ships to.
export interface TailnetSidecarConfig {
  headscaleAddr: string;
  headscaleServerName?: string;
  caPem: string;
  clientCertPem: string;
  clientKeyPem: string;
  preauthKey?: string;
  stateDir: string;
  hostname: string;
}

export interface StartTailnetSidecarOptions {
  binaryPath: string;
  config: TailnetSidecarConfig;

  // Bounds how long to wait for the readiness line. The join crosses the
  // hosted relay, so it is generous, but bounded: without a limit a control
  // plane that never answers would leave the desktop app stuck on a splash
  // screen with no error.
  readyTimeoutMs?: number;

  // Diagnostics sink. The sidecar's stderr is forwarded here rather than
  // inherited so it can be surfaced in the app's own logs.
  logf?: (message: string) => void;

  // Injectable for tests, which need to observe the spawn without a real
  // binary on disk.
  spawnFn?: typeof spawn;
}

export interface TailnetSidecar {
  proxy: TailnetProxy;
  tailnetIps: string[];
  stop: () => Promise<void>;
}

const DEFAULT_READY_TIMEOUT_MS = 120_000;

// How long to give the process to exit on its own before killing it. Short,
// because the sidecar has nothing to flush: its state is written as it goes.
const STOP_GRACE_MS = 5_000;

// The readiness line the sidecar writes once the tailnet is up.
interface ReadyMessage {
  socks_addr: string;
  socks_username: string;
  socks_password: string;
  tailnet_ips?: string[];
  control_url?: string;
}

// Validates the readiness line, because a sidecar that announced itself without
// usable SOCKS5 details would leave every upstream request failing later with
// no indication of why.
const parseReadyMessage = (line: string): ReadyMessage | null => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) {
    return null;
  }
  const candidate = parsed as Partial<ReadyMessage>;
  if (
    typeof candidate.socks_addr !== "string" ||
    candidate.socks_addr.length === 0 ||
    typeof candidate.socks_username !== "string" ||
    typeof candidate.socks_password !== "string"
  ) {
    return null;
  }
  return candidate as ReadyMessage;
};

// Translates the config into the wire shape the Go sidecar expects. Kept
// explicit so a rename on either side is a type error rather than a field the
// sidecar silently reads as empty.
const toSidecarInput = (config: TailnetSidecarConfig): Record<string, string> => ({
  headscale_addr: config.headscaleAddr,
  headscale_server_name: config.headscaleServerName ?? "",
  ca_pem: config.caPem,
  client_cert_pem: config.clientCertPem,
  client_key_pem: config.clientKeyPem,
  preauth_key: config.preauthKey ?? "",
  state_dir: config.stateDir,
  hostname: config.hostname,
});

// Launches the tsnet sidecar and waits until it has joined the tailnet.
//
// This exists because gitd no longer listens on a host port: it is reachable
// only from inside the tailnet. Node cannot join a tailnet itself, so a Go
// sidecar joins on its behalf and publishes a loopback SOCKS5 proxy that the
// existing mTLS agents dial through.
//
// Resolving only once the tailnet is actually up matters: the app would
// otherwise start issuing requests that fail for reasons indistinguishable
// from the server being down.
export const startTailnetSidecar = async ({
  binaryPath,
  config,
  readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
  logf = () => {},
  spawnFn = spawn,
}: StartTailnetSidecarOptions): Promise<TailnetSidecar> => {
  const child: ChildProcess = spawnFn(binaryPath, [], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  const stop = async (): Promise<void> => {
    if (child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    const exited = new Promise<void>((resolveExit) => {
      child.once("exit", () => resolveExit());
    });
    child.kill("SIGTERM");
    // The tailnet only exists while the sidecar runs, so a process that
    // ignores SIGTERM has to be killed rather than left holding the node.
    const timer = setTimeout(() => child.kill("SIGKILL"), STOP_GRACE_MS);
    try {
      await exited;
    } finally {
      clearTimeout(timer);
    }
  };

  if (child.stderr) {
    createInterface({ input: child.stderr }).on("line", (line) => logf(`tsnet-sidecar: ${line}`));
  }

  // The config is written and stdin closed immediately: the sidecar reads it
  // to EOF, so leaving the pipe open would hang it before it ever starts.
  if (!child.stdin) {
    await stop();
    throw new Error("Tailnet sidecar was spawned without a stdin pipe.");
  }
  child.stdin.end(`${JSON.stringify(toSidecarInput(config))}\n`);

  if (!child.stdout) {
    await stop();
    throw new Error("Tailnet sidecar was spawned without a stdout pipe.");
  }

  const ready = await new Promise<ReadyMessage>((resolveReady, rejectReady) => {
    const lines = createInterface({ input: child.stdout! });

    const timer = setTimeout(() => {
      cleanup();
      rejectReady(
        new Error(
          `Tailnet sidecar did not join the tailnet within ${readyTimeoutMs}ms. ` +
            "The headscale control plane may be unreachable.",
        ),
      );
    }, readyTimeoutMs);

    const cleanup = () => {
      clearTimeout(timer);
      lines.close();
      child.off("exit", onExit);
      child.off("error", onError);
    };

    // An early exit is the common failure - a bad credential, an unreachable
    // control plane - and must reject rather than wait out the timeout.
    const onExit = (code: number | null, signal: string | null) => {
      cleanup();
      rejectReady(
        new Error(`Tailnet sidecar exited before joining the tailnet (code=${code} signal=${signal}).`),
      );
    };
    const onError = (error: Error) => {
      cleanup();
      rejectReady(new Error(`Tailnet sidecar could not be started: ${error.message}`));
    };

    child.once("exit", onExit);
    child.once("error", onError);

    lines.on("line", (line) => {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        return;
      }
      const message = parseReadyMessage(trimmed);
      if (!message) {
        // Not fatal: forward it so an unexpected stdout line is visible
        // rather than silently discarded.
        logf(`tsnet-sidecar: unexpected stdout: ${trimmed}`);
        return;
      }
      cleanup();
      resolveReady(message);
    });
  }).catch(async (error: unknown) => {
    await stop();
    throw error;
  });

  return {
    proxy: {
      socksAddr: ready.socks_addr,
      socksUsername: ready.socks_username,
      socksPassword: ready.socks_password,
    },
    tailnetIps: ready.tailnet_ips ?? [],
    stop,
  };
};
