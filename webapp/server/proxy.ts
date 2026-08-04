import { createHash } from "node:crypto";
import { request as httpRequest, IncomingMessage } from "node:http";
import { Agent, request as httpsRequest } from "node:https";
import { pipeline } from "node:stream/promises";
import { Buffer } from "node:buffer";
import { URL } from "node:url";
import { Request, Response } from "express";

// Browser-owned mTLS credentials used to authenticate against gitd on the
// browser's behalf, since browsers cannot perform mTLS themselves.
export interface MtlsMaterial {
  keyPem: string;
  certPem: string;
}

// Captures runtime values needed by the proxy forwarder while setup state remains externally managed.
export interface ForwarderRuntimeConfig {
  getUpstreamCa: () => string | undefined;
  getSessionMtlsMaterial: (req: Request) => MtlsMaterial | undefined;
  agentPool?: MtlsAgentPool;
}

export const CLIENT_KEY_HEADER = "x-replycant-client-key";
export const CLIENT_CERT_HEADER = "x-replycant-client-cert";
const DEFAULT_AGENT_POOL_MAX_ENTRIES = 8;
const DEFAULT_AGENT_KEEP_ALIVE_MS = 15_000;
const DEFAULT_AGENT_MAX_SOCKETS = 32;
const DEFAULT_AGENT_MAX_FREE_SOCKETS = 4;

const HOP_BY_HOP_RESPONSE_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

// Captures the agent identity inputs that define which TLS connection pool is safe to reuse.
export interface MtlsAgentIdentity {
  upstreamCa: string;
  mtlsMaterial: MtlsMaterial | null;
}

// Exposes bounded TLS agent reuse so bursty media traffic does not rebuild handshakes per request.
export interface MtlsAgentPool {
  acquire: (identity: MtlsAgentIdentity) => Agent;
  destroy: () => void;
}

interface CreateMtlsAgentPoolOptions {
  maxEntries?: number;
}

// Generates a stable cache key without retaining additional plaintext PEM copies in map keys.
const buildMtlsAgentKey = ({ upstreamCa, mtlsMaterial }: MtlsAgentIdentity): string =>
  createHash("sha256")
    .update(upstreamCa)
    .update("\n")
    .update(mtlsMaterial?.keyPem ?? "")
    .update("\n")
    .update(mtlsMaterial?.certPem ?? "")
    .digest("hex");

// Maintains a small LRU of upstream TLS agents so the proxy can reuse sockets safely.
export const createMtlsAgentPool = ({
  maxEntries = DEFAULT_AGENT_POOL_MAX_ENTRIES,
}: CreateMtlsAgentPoolOptions = {}): MtlsAgentPool => {
  const entries = new Map<string, Agent>();

  const evictLeastRecentlyUsed = () => {
    if (entries.size <= maxEntries) {
      return;
    }
    const oldestKey = entries.keys().next().value;
    if (!oldestKey) {
      return;
    }
    const oldestAgent = entries.get(oldestKey);
    if (oldestAgent) {
      oldestAgent.destroy();
    }
    entries.delete(oldestKey);
  };

  return {
    acquire: (identity) => {
      const key = buildMtlsAgentKey(identity);
      const existing = entries.get(key);
      if (existing) {
        entries.delete(key);
        entries.set(key, existing);
        return existing;
      }
      const created = new Agent({
        ca: identity.upstreamCa,
        key: identity.mtlsMaterial?.keyPem,
        cert: identity.mtlsMaterial?.certPem,
        rejectUnauthorized: true,
        keepAlive: true,
        keepAliveMsecs: DEFAULT_AGENT_KEEP_ALIVE_MS,
        maxSockets: DEFAULT_AGENT_MAX_SOCKETS,
        maxFreeSockets: DEFAULT_AGENT_MAX_FREE_SOCKETS,
      });
      entries.set(key, created);
      evictLeastRecentlyUsed();
      return created;
    },
    destroy: () => {
      for (const agent of entries.values()) {
        agent.destroy();
      }
      entries.clear();
    },
  };
};

// Decodes base64-encoded PEM credentials, rejecting anything that is not a
// plausible key/certificate pair before it reaches the TLS agent.
export const decodeMtlsMaterial = (
  encodedKey: string | undefined,
  encodedCert: string | undefined,
): MtlsMaterial | null => {
  if (!encodedKey || !encodedCert) return null;
  try {
    const keyPem = Buffer.from(encodedKey, "base64").toString("utf8");
    const certPem = Buffer.from(encodedCert, "base64").toString("utf8");
    if (!keyPem.includes("BEGIN") || !certPem.includes("BEGIN CERTIFICATE")) return null;
    return { keyPem, certPem };
  } catch {
    return null;
  }
};

// Picks the identity to authenticate an upstream call with.
//
// Per-request headers take precedence so a request that carries its own
// identity is never attributed to another browser's session. The session
// fallback exists purely for media element requests: `<video src>` cannot set
// headers, so those requests rely on the identity the browser registered
// through /api/setup/session.
export const resolveRequestMtlsMaterial = (
  req: Request,
  getSessionMtlsMaterial: (req: Request) => MtlsMaterial | undefined,
): MtlsMaterial | null =>
  decodeMtlsMaterial(req.header(CLIENT_KEY_HEADER), req.header(CLIENT_CERT_HEADER)) ??
  getSessionMtlsMaterial(req) ??
  null;

// Validates Smart HTTP payload type so git clients never parse JSON/HTML as pkt-line data.
export const isGitSmartHttpContentType = (rawContentType: string): boolean => {
  const contentType = rawContentType.split(";")[0]?.trim().toLowerCase() ?? "";
  return (
    contentType === "application/x-git-upload-pack-advertisement" ||
    contentType === "application/x-git-upload-pack-result" ||
    contentType === "application/x-git-receive-pack-advertisement" ||
    contentType === "application/x-git-receive-pack-result"
  );
};

// Builds a stable protocol mismatch detail so clients can surface actionable setup guidance.
export const describeGitSmartHttpMismatch = (statusCode: number, rawContentType: string): string => {
  const contentType = rawContentType || "missing";
  return `Expected git smart-HTTP response but got status=${statusCode} content-type=${contentType}.`;
};

// Filters hop-by-hop headers so proxy forwarding preserves valid end-to-end response semantics.
export const filterProxyResponseHeaders = (
  headers: IncomingMessage["headers"],
  blocked: string[] = [],
): Array<[string, string | string[]]> => {
  const blockedHeaders = new Set(blocked.map((name) => name.toLowerCase()));
  const forwarded: Array<[string, string | string[]]> = [];
  for (const [name, value] of Object.entries(headers)) {
    const lowerName = name.toLowerCase();
    if (value === undefined) continue;
    if (HOP_BY_HOP_RESPONSE_HEADERS.has(lowerName)) continue;
    if (blockedHeaders.has(lowerName)) continue;
    forwarded.push([name, value]);
  }
  return forwarded;
};

// Keeps streamed git responses parseable by dropping conflicting length hints for chunked payloads.
export const buildForwardedResponseHeaders = (
  headers: IncomingMessage["headers"],
  options?: { expectsGitSmartHttp?: boolean },
): Array<[string, string | string[]]> => {
  const forwarded = filterProxyResponseHeaders(headers);
  if (!options?.expectsGitSmartHttp) {
    return forwarded;
  }
  const transferEncoding = headers["transfer-encoding"];
  const encodings = Array.isArray(transferEncoding) ? transferEncoding.join(",") : (transferEncoding ?? "");
  const isChunked = encodings.toLowerCase().includes("chunked");
  if (!isChunked) {
    return forwarded;
  }
  return forwarded.filter(([name]) => name.toLowerCase() !== "content-length");
};

export interface Forwarder {
  (
    req: Request,
    res: Response,
    baseUrl: string,
    options?: {
      forceLfsAccept?: boolean;
      requiresMtlsMaterial?: boolean;
      expectsGitSmartHttp?: boolean;
    },
  ): Promise<void>;
  destroy: () => void;
}

// Enforces mTLS for git calls while sharing one path for all upstream forwarding.
export const createForwarder = (config: ForwarderRuntimeConfig) => {
  const pool = config.agentPool ?? createMtlsAgentPool();
  const ownedPool = config.agentPool ? null : pool;

  // Streams request/response bodies to preserve large media and git payload semantics.
  const forward: Forwarder = async (
    req: Request,
    res: Response,
    baseUrl: string,
    options?: {
      forceLfsAccept?: boolean;
      requiresMtlsMaterial?: boolean;
      expectsGitSmartHttp?: boolean;
    },
  ) => {
    let clientAborted = false;
    try {
      const splat = req.params.splat;
      const path = Array.isArray(splat) ? splat.join("/") : (splat ?? "");
      const upstreamUrl = new URL(`${baseUrl.replace(/\/$/, "")}/${path}`);
      if (req.url.includes("?")) {
        upstreamUrl.search = req.url.split("?")[1] ?? "";
      }

      const headers = { ...req.headers } as Record<string, string | string[] | undefined>;
      delete headers.host;
      delete headers[CLIENT_KEY_HEADER];
      delete headers[CLIENT_CERT_HEADER];
      if (options?.forceLfsAccept) {
        headers.accept = "application/vnd.git-lfs";
      }

      const mtlsMaterial = options?.requiresMtlsMaterial
        ? resolveRequestMtlsMaterial(req, config.getSessionMtlsMaterial)
        : null;
      if (options?.requiresMtlsMaterial) {
        console.info(
          `[proxy] mTLS check: hasMaterial=${Boolean(mtlsMaterial)} hasKeyHeader=${Boolean(req.header(CLIENT_KEY_HEADER))} hasCertHeader=${Boolean(req.header(CLIENT_CERT_HEADER))} method=${req.method} path="${req.url}"`,
        );
      }
      if (options?.requiresMtlsMaterial && !mtlsMaterial) {
        console.warn(`[proxy] mTLS credentials missing or invalid, rejecting ${req.method} ${req.url}`);
        res.status(401).json({ error: "Missing or invalid request mTLS credentials." });
        return;
      }
      const httpsAgent =
        upstreamUrl.protocol === "https:"
          ? (() => {
              const upstreamCa = config.getUpstreamCa();
              if (!upstreamCa) {
                if (!res.headersSent) {
                  res.status(503).json({ error: "Server setup incomplete. Missing upstream CA certificate." });
                }
                return undefined;
              }
              return pool.acquire({ upstreamCa, mtlsMaterial });
            })()
          : undefined;
      if (upstreamUrl.protocol === "https:" && !httpsAgent) {
        return;
      }

      const requestFn = upstreamUrl.protocol === "https:" ? httpsRequest : httpRequest;
      const upstream = requestFn(
        upstreamUrl,
        {
          method: req.method,
          headers,
          agent: httpsAgent,
        },
        (upstreamRes: IncomingMessage) => {
          void (async () => {
            const statusCode = upstreamRes.statusCode ?? 502;
            const contentType = String(upstreamRes.headers["content-type"] ?? "");
            if (options?.expectsGitSmartHttp) {
              console.info(
                `[proxy] git upstream status=${statusCode} content-type="${contentType || "missing"}" content-length="${String(
                  upstreamRes.headers["content-length"] ?? "unknown",
                )}" url="${upstreamUrl.pathname}${upstreamUrl.search}"`,
              );
            }
            if (
              options?.expectsGitSmartHttp &&
              statusCode >= 200 &&
              statusCode < 300 &&
              !isGitSmartHttpContentType(contentType)
            ) {
              const detail = describeGitSmartHttpMismatch(statusCode, contentType);
              console.error(
                `[proxy] git upstream protocol mismatch url="${upstreamUrl.pathname}${upstreamUrl.search}" detail="${detail}"`,
              );
              // Aborts upstream stream so git clients receive one deterministic transport failure response.
              upstreamRes.destroy();
              if (!res.headersSent) {
                res.status(502);
                res.setHeader("content-type", "text/plain; charset=utf-8");
                res.end(`Git upstream protocol mismatch. ${detail}`);
              }
              return;
            }
            try {
              res.status(statusCode);
              for (const [name, value] of buildForwardedResponseHeaders(upstreamRes.headers, options)) {
                res.setHeader(name, value);
              }
              if (options?.expectsGitSmartHttp) {
                res.setHeader("Cache-Control", "no-store");
              }
              await pipeline(upstreamRes, res);
            } catch {
              // Swallows stream aborts so one broken client fetch does not crash the proxy.
            }
          })();
        },
      );

      res.on("close", () => {
        if (res.writableFinished) {
          return;
        }
        clientAborted = true;
        upstream.destroy();
      });

      upstream.on("error", (error) => {
        if (clientAborted) {
          return;
        }
        console.error(
          `[proxy] upstream connection error: method=${req.method} url="${upstreamUrl.href}" error="${error.message}"`,
        );
        if (res.headersSent) return;
        res.status(502).json({
          error: "Proxy upstream request failed",
          detail: error.message,
        });
      });

      const method = (req.method ?? "GET").toUpperCase();
      if (method === "GET" || method === "HEAD" || method === "OPTIONS") {
        upstream.end();
        return;
      }

      await pipeline(req, upstream);
    } catch (error) {
      if (clientAborted) {
        return;
      }
      console.error(
        `[proxy] forwarder exception: method=${req.method} url="${req.url}" error="${error instanceof Error ? error.message : String(error)}"`,
      );
      if (res.headersSent) return;
      res.status(502).json({
        error: "Proxy upstream request failed",
        detail: error instanceof Error ? error.message : "unknown error",
      });
    }
  };

  // Releases keep-alive sockets owned by this forwarder when the hosting server shuts down.
  forward.destroy = () => {
    ownedPool?.destroy();
  };
  return forward;
};
