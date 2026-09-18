export type DevApiMode =
  | { mode: "in-process" }
  | { mode: "proxy"; target: string };

// Chooses whether Vite serves `/api` itself or forwards it to Electron.
//
// Browser `npm run dev` has no tailnet sidecar, so the in-process app is the
// only option. desktop:dev joins the tailnet in Electron; without this split,
// Vite dials gitd.replycant.internal on the host stack and every sync 502s.
export const resolveDevApiMode = (
  env: Record<string, string | undefined> = process.env,
): DevApiMode => {
  const target = env.REPLYCANT_DESKTOP_API?.trim();
  if (!target) {
    return { mode: "in-process" };
  }
  return { mode: "proxy", target };
};

// Reads the loopback port Electron must bind so Vite's `/api` proxy has a
// listener. Port 0 would silently pick an ephemeral port Vite does not know.
export const resolveDesktopApiListenPort = (
  raw: string | undefined = process.env.REPLYCANT_DESKTOP_API,
): number => {
  const value = raw?.trim();
  if (!value) {
    throw new Error("REPLYCANT_DESKTOP_API is required to bind the desktop-dev API server.");
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`REPLYCANT_DESKTOP_API is not a valid URL: ${value}`);
  }
  const port = Number(url.port);
  if (!Number.isInteger(port) || port <= 0) {
    throw new Error(`REPLYCANT_DESKTOP_API must include an explicit port, got ${value}`);
  }
  return port;
};
