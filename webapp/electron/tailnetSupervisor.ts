import { join } from "node:path";
import {
  startTailnetSidecar,
  StartTailnetSidecarOptions,
  TailnetSidecar,
  TailnetSidecarConfig,
} from "../server/tailnetSidecar";
import { TailnetProxy } from "../server/proxy";

// Name of the bundled Go binary. Windows needs the extension for spawn to find
// it, and electron-builder does not rename resources per platform.
const SIDECAR_BASENAME = process.platform === "win32" ? "replycant-tsnet.exe" : "replycant-tsnet";

export interface ResolveSidecarPathOptions {
  // Where electron-builder unpacks `extraResources` in a packaged app.
  resourcesPath: string;

  // The repository root when running unpackaged, so `npm run desktop:dev`
  // picks up a locally built binary instead of failing.
  projectRoot: string;

  packaged: boolean;
}

// Locates the sidecar binary.
//
// This is the first native executable the desktop app has ever shipped, so the
// packaged and unpackaged layouts genuinely differ: electron-builder places
// `extraResources` under `process.resourcesPath`, while a development build has
// only whatever `make webapp-sidecar` produced in the source tree.
export const resolveSidecarPath = ({
  resourcesPath,
  projectRoot,
  packaged,
}: ResolveSidecarPathOptions): string =>
  packaged
    ? join(resourcesPath, SIDECAR_BASENAME)
    : join(projectRoot, "sidecar", "build", SIDECAR_BASENAME);

export interface TailnetSupervisor {
  // The proxy the upstream agents dial through, or undefined when the tailnet
  // is not up. Read on every agent acquire, so it must stay cheap.
  getProxy: () => TailnetProxy | undefined;

  // Brings the tailnet up, replacing any existing node. Idempotent from the
  // renderer's point of view: reconfiguring is a restart.
  start: (config: TailnetSidecarConfig) => Promise<TailnetProxy>;

  stop: () => Promise<void>;

  isRunning: () => boolean;
}

export interface CreateTailnetSupervisorOptions {
  binaryPath: string;
  logf?: (message: string) => void;

  // Injectable so tests can drive the supervisor without a real binary.
  startFn?: (options: StartTailnetSidecarOptions) => Promise<TailnetSidecar>;
}

// Owns the lifetime of the tailnet node for the desktop app.
//
// The node cannot be started at app launch: it needs the credentials from the
// pairing record, which the renderer holds. So the renderer starts it once
// onboarding has produced them, and this supervisor keeps the resulting proxy
// available to the HTTP server that was already running.
//
// Restarting on reconfiguration rather than refusing matters because a user can
// re-pair a device, and the old node would then be holding a credential the
// deployment has revoked.
export const createTailnetSupervisor = ({
  binaryPath,
  logf = () => {},
  startFn = startTailnetSidecar,
}: CreateTailnetSupervisorOptions): TailnetSupervisor => {
  let current: TailnetSidecar | null = null;

  // Serialises start and stop. Without this, two overlapping starts would each
  // spawn a sidecar and one would be leaked, holding the tailnet node and the
  // loopback ports the other needs.
  let pending: Promise<unknown> = Promise.resolve();
  const serialise = <T,>(work: () => Promise<T>): Promise<T> => {
    const result = pending.then(work, work);
    pending = result.catch(() => {});
    return result;
  };

  const stopCurrent = async (): Promise<void> => {
    if (!current) {
      return;
    }
    const sidecar = current;
    current = null;
    try {
      await sidecar.stop();
    } catch (error) {
      // Shutdown failures must not block the app from quitting or from
      // starting a replacement node.
      logf(`tailnet: failed to stop the sidecar cleanly: ${String(error)}`);
    }
  };

  return {
    getProxy: () => current?.proxy,

    isRunning: () => current !== null,

    start: (config) =>
      serialise(async () => {
        await stopCurrent();

        const sidecar = await startFn({ binaryPath, config, logf });
        current = sidecar;
        logf(
          `tailnet: joined as ${config.hostname} with addresses ${sidecar.tailnetIps.join(", ") || "none"}`,
        );
        return sidecar.proxy;
      }),

    stop: () => serialise(stopCurrent),
  };
};
