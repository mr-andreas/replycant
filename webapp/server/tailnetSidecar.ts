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

  // Where the control plane can be reached from inside the tailnet, so the
  // sidecar can stop routing control traffic through the hosted relay once the
  // node is up. Optional: without it the relay stays the only path, which is
  // exactly the behaviour a deployment that turned the in-tailnet relay off
  // should get.
  gitdControlAddr?: string;
  gitdControlServerName?: string;

  caPem: string;
  clientCertPem: string;
  clientKeyPem: string;
  preauthKey?: string;
  stateDir: string;
  hostname: string;
}

// What the app knows about the tailnet at a point in time.
//
// This exists because a failed request used to be ambiguous: the device could
// be off the tailnet, on it but unable to route, or on it with the server down,
// and all three looked identical. Every field is here to make that
// distinction visible.
export interface TailnetStatus {
  // One of tailscale's backend states, or "Unknown" when the node did not
  // answer. Only "Running" means traffic can flow.
  backendState: string;

  tailnetIps: string[];

  // The DERP region carrying this node's traffic.
  derpHome: string;

  // Which path the last control session took, "tailnet" or "relay". A device
  // permanently on the relay is a deployment problem with no other symptom.
  controlRoute: string;

  // How Git and LFS currently reach gitd. Distinct from controlRoute: that
  // hop is the shim's path to headscale.
  serverPath: string;
  serverRelay: string;

  peers: number;
  peersOnline: number;

  // tailscale's own warnings: a node can be Running and still unable to carry
  // traffic.
  health: string[];

  lastError?: string;
}

export interface StartTailnetSidecarOptions {
  binaryPath: string;
  config: TailnetSidecarConfig;

  // Called for every status event the sidecar emits, which is roughly every
  // five seconds for the life of the process. Optional so callers that only
  // need the proxy are unaffected.
  onStatus?: (status: TailnetStatus) => void;

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

// The periodic status line the sidecar writes for the life of the process.
interface StatusMessage {
  backend_state?: string;
  tailnet_ips?: string[];
  derp_home?: string;
  control_route?: string;
  server_path?: string;
  server_relay?: string;
  peers?: number;
  peers_online?: number;
  health?: string[];
  last_error?: string;
}

// One line of the sidecar's stdout stream.
//
// stdout is a stream of typed events rather than a single readiness line,
// because the tailnet's health changes over the process's life and the app has
// to be able to report it.
const parseEvent = (line: string): { type?: unknown } | null => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) {
    return null;
  }
  return parsed as { type?: unknown };
};

// Validates the readiness line, because a sidecar that announced itself without
// usable SOCKS5 details would leave every upstream request failing later with
// no indication of why.
const parseReadyMessage = (event: { type?: unknown }): ReadyMessage | null => {
  const candidate = event as Partial<ReadyMessage>;
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

// Normalises a status line into the shape the renderer consumes.
//
// Defaults rather than rejection for missing fields: a status event is only
// ever advisory, and dropping one because a field was absent would freeze the
// panel on a stale reading that claims everything is fine.
const toTailnetStatus = (event: { type?: unknown }): TailnetStatus => {
  const message = event as StatusMessage;
  return {
    backendState: typeof message.backend_state === "string" ? message.backend_state : "Unknown",
    tailnetIps: Array.isArray(message.tailnet_ips) ? message.tailnet_ips : [],
    derpHome: typeof message.derp_home === "string" ? message.derp_home : "",
    controlRoute: typeof message.control_route === "string" ? message.control_route : "",
    serverPath: typeof message.server_path === "string" ? message.server_path : "",
    serverRelay: typeof message.server_relay === "string" ? message.server_relay : "",
    peers: typeof message.peers === "number" ? message.peers : 0,
    peersOnline: typeof message.peers_online === "number" ? message.peers_online : 0,
    health: Array.isArray(message.health) ? message.health : [],
    lastError: typeof message.last_error === "string" ? message.last_error : undefined,
  };
};

// Translates the config into the wire shape the Go sidecar expects. Kept
// explicit so a rename on either side is a type error rather than a field the
// sidecar silently reads as empty.
const toSidecarInput = (config: TailnetSidecarConfig): Record<string, string> => ({
  headscale_addr: config.headscaleAddr,
  headscale_server_name: config.headscaleServerName ?? "",
  gitd_control_addr: config.gitdControlAddr ?? "",
  gitd_control_server_name: config.gitdControlServerName ?? "",
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
  onStatus,
  readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
  logf = () => {},
  spawnFn = spawn,
}: StartTailnetSidecarOptions): Promise<TailnetSidecar> => {
  const child: ChildProcess = spawnFn(binaryPath, [], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  // Assigned once the stdout reader exists. Held so stopping the sidecar also
  // stops the status stream, rather than leaving a reader attached to a pipe
  // that is about to close.
  let stopReading: (() => void) | undefined;

  const stop = async (): Promise<void> => {
    if (child.exitCode !== null || child.signalCode !== null) {
      return;
    }
    stopReading?.();
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

  // One reader for the whole stream, kept open past readiness: status events
  // arrive on the same stdout for the life of the process, so closing it after
  // the readiness line would leave the app with no way to see the tailnet's
  // state change.
  const lines = createInterface({ input: child.stdout });
  stopReading = () => lines.close();

  const ready = await new Promise<ReadyMessage>((resolveReady, rejectReady) => {
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
      const event = parseEvent(trimmed);
      if (event?.type === "status") {
        // Status can arrive before readiness if the node comes up while the
        // readiness line is still being written; it is not readiness.
        onStatus?.(toTailnetStatus(event));
        return;
      }
      const message = event ? parseReadyMessage(event) : null;
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
    lines.close();
    await stop();
    throw error;
  });

  // Readiness is settled, so from here every line is a status update.
  lines.removeAllListeners("line");
  lines.on("line", (line) => {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return;
    }
    const event = parseEvent(trimmed);
    if (event?.type === "status") {
      onStatus?.(toTailnetStatus(event));
      return;
    }
    logf(`tsnet-sidecar: unexpected stdout: ${trimmed}`);
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
