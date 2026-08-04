import { randomUUID } from "node:crypto";
import express, { Request, Response } from "express";
import { ProxyConfig, resolveDecryptdBaseUrl, resolveTranscodedBaseUrl } from "./config";
import { CLIENT_CERT_HEADER, CLIENT_KEY_HEADER, createForwarder, decodeMtlsMaterial, MtlsAgentPool } from "./proxy";
import { createSetupState, deriveLfsBaseUrl, DiscoveredServerConfig, SetupState } from "./setupState";

export type ForwarderOptions = {
  forceLfsAccept?: boolean;
  requiresMtlsMaterial?: boolean;
  expectsGitSmartHttp?: boolean;
};

const SESSION_COOKIE_NAME = "replycant.session";

// Reads the proxy session id without taking on a cookie-parser dependency for
// the single cookie this server issues.
const readSessionId = (req: Request): string | undefined => {
  const header = req.headers.cookie;
  if (!header) return undefined;
  for (const part of header.split(";")) {
    const separatorIndex = part.indexOf("=");
    if (separatorIndex === -1) continue;
    if (part.slice(0, separatorIndex).trim() !== SESSION_COOKIE_NAME) continue;
    return decodeURIComponent(part.slice(separatorIndex + 1).trim());
  }
  return undefined;
};
export type Forwarder = (
  req: Request,
  res: Response,
  baseUrl: string,
  options?: ForwarderOptions,
) => Promise<void>;

// Builds the proxy API surface so request routing can be unit tested without binding a port.
export const createApp = (
  config: ProxyConfig,
  injectedForwarder?: Forwarder,
  setupState: SetupState = createSetupState({
    upstreamCa: config.upstreamCa,
    gitBaseUrl: config.gitBaseUrl,
    lfsBaseUrl: config.gitBaseUrl ? deriveLfsBaseUrl(config.gitBaseUrl) : undefined,
  }),
  agentPool?: MtlsAgentPool,
) => {
  const app = express();
  const forward =
    injectedForwarder ??
    createForwarder({
      getUpstreamCa: () => setupState.getConfig().upstreamCa,
      getSessionMtlsMaterial: (req) => setupState.getSessionMtlsMaterial(readSessionId(req)),
      agentPool,
    });
  app.use(express.json());

  // Parses and validates caserver config payloads so setup endpoints reject malformed input consistently.
  const parseDiscoveredConfig = (value: unknown): DiscoveredServerConfig | null => {
    if (!value || typeof value !== "object") return null;
    const candidate = value as Record<string, unknown>;
    if (
      typeof candidate.ca !== "string" ||
      typeof candidate.url !== "string"
    ) {
      return null;
    }
    const ca = candidate.ca.trim();
    const url = candidate.url.trim();
    if (!ca || !url) return null;
    try {
      // Uses URL parsing as a strict gate so proxy setup never stores malformed origins.
      // eslint-disable-next-line no-new
      new URL(url);
    } catch {
      return null;
    }
    return { ca, url };
  };

  // Keeps local diagnostics available before full sync path is configured.
  app.get("/api/health", (_req, res) => {
    res.json({ status: "ok" });
  });

  // Discovers setup config from caserver so browser onboarding can own durable setup state.
  app.post("/api/setup/discover", async (req, res) => {
    const rawServerUrl = typeof req.body?.serverUrl === "string" ? req.body.serverUrl.trim() : "";
    if (!rawServerUrl) {
      res.status(400).json({ error: "serverUrl is required." });
      return;
    }
    let configUrl: URL;
    try {
      configUrl = new URL(rawServerUrl);
    } catch {
      res.status(400).json({ error: "serverUrl must be a valid URL." });
      return;
    }
    const endpoint = new URL("./config.json", configUrl);
    let response: globalThis.Response;
    try {
      response = await fetch(endpoint);
    } catch (error) {
      // Node fetch (undici) wraps the real cause in error.cause; surface
      // it so users see "ENOTFOUND" / "ECONNREFUSED" instead of "fetch failed".
      const rootCause =
        error instanceof Error && error.cause instanceof Error
          ? error.cause
          : error instanceof Error
            ? error
            : null;
      res.status(502).json({
        error: "Failed to fetch server configuration:",
        detail: rootCause ? rootCause.message : String(error),
      });
      return;
    }
    if (!response.ok) {
      res.status(502).json({
        error: `Server configuration endpoint returned ${response.status}.`,
      });
      return;
    }
    let payload: unknown;
    try {
      payload = await response.json();
    } catch {
      res.status(502).json({ error: "Server configuration endpoint returned invalid JSON." });
      return;
    }
    const parsed = parseDiscoveredConfig(payload);
    if (!parsed) {
      res.status(502).json({ error: "Server configuration endpoint returned an invalid payload." });
      return;
    }
    res.json(parsed);
  });

  // Applies browser-owned setup configuration to runtime proxy state after discovery or reload.
  app.post("/api/setup/configure", (req, res) => {
    const parsed = parseDiscoveredConfig(req.body);
    if (!parsed) {
      res.status(400).json({ error: "Expected { ca, url } with valid non-empty values." });
      return;
    }
    setupState.setDiscoveredConfig(parsed);
    res.status(204).end();
  });

  // Registers the browser's mTLS identity for the lifetime of a session.
  //
  // Media playback sets `video.src` directly, and a media element cannot attach
  // the per-request mTLS headers the other proxy routes rely on. Binding the
  // identity to an httpOnly session cookie lets those header-less requests
  // authenticate while keeping concurrent browsers attributed to their own
  // device certificate.
  app.post("/api/setup/session", (req, res) => {
    const material = decodeMtlsMaterial(req.body?.[CLIENT_KEY_HEADER], req.body?.[CLIENT_CERT_HEADER]);
    if (!material) {
      res.status(400).json({ error: "Expected base64-encoded PEM client key and certificate." });
      return;
    }
    const sessionId = randomUUID();
    setupState.setSessionMtlsMaterial(sessionId, material);
    res.cookie(SESSION_COOKIE_NAME, sessionId, {
      httpOnly: true,
      sameSite: "strict",
      path: "/",
    });
    res.status(204).end();
  });

  // Proxies git smart HTTP endpoints with mTLS that browsers cannot perform directly.
  app.all("/api/git/*splat", async (req, res) => {
    const runtime = setupState.getConfig();
    if (!setupState.isConfigured() || !runtime.gitBaseUrl) {
      res.status(503).json({ error: "Server setup incomplete. Configure server URL and CA first." });
      return;
    }
    await forward(req, res, runtime.gitBaseUrl, { requiresMtlsMaterial: true, expectsGitSmartHttp: true });
  });

  // Proxies LFS requests over browser-provided mTLS material.
  app.all("/api/lfs/*splat", async (req, res) => {
    const runtime = setupState.getConfig();
    if (!setupState.isConfigured() || !runtime.lfsBaseUrl) {
      res.status(503).json({ error: "Server setup incomplete. Configure server URL and CA first." });
      return;
    }
    await forward(req, res, runtime.lfsBaseUrl, { forceLfsAccept: true, requiresMtlsMaterial: true });
  });

  // Proxies transcoded media access used for HLS playback compatibility.
  // Playlists reference their variants and segments relatively, so they need no
  // rewriting to stay under this prefix.
  app.all("/api/transcoded/*splat", async (req, res) => {
    const runtime = setupState.getConfig();
    const transcodedBaseUrl = resolveTranscodedBaseUrl(config.transcodedBaseUrl, runtime.gitBaseUrl);
    if (!transcodedBaseUrl) {
      res.status(503).json({ error: "Server setup incomplete. Configure server URL first." });
      return;
    }
    await forward(req, res, transcodedBaseUrl, { requiresMtlsMaterial: true });
  });

  // Proxies direct-play decryptd media by converting query params into decryptd header inputs.
  app.all("/api/decryptd/*splat", async (req, res) => {
    const runtime = setupState.getConfig();
    const decryptdBaseUrl = resolveDecryptdBaseUrl(config.decryptdBaseUrl, runtime.gitBaseUrl);
    if (!decryptdBaseUrl) {
      res.status(503).json({ error: "Server setup incomplete. Configure server URL first." });
      return;
    }
    const dekParam = typeof req.query.dek === "string" ? req.query.dek.trim() : "";
    if (!dekParam) {
      res.status(400).json({ error: "Missing dek query parameter." });
      return;
    }
    req.headers["x-replycant-dek"] = dekParam;

    const cleanPath = req.path;
    req.url = cleanPath;
    req.originalUrl = cleanPath;
    await forward(req, res, decryptdBaseUrl, { requiresMtlsMaterial: true });
  });

  return app;
};
