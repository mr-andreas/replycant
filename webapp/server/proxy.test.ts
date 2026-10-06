import { once } from "node:events";
import { createServer } from "node:http";
import { Writable } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import type { Request, Response } from "express";
import {
  buildForwardedResponseHeaders,
  createForwarder,
  createMtlsAgentPool,
  CLIENT_CERT_HEADER,
  CLIENT_KEY_HEADER,
  describeGitSmartHttpMismatch,
  filterProxyResponseHeaders,
  isGitSmartHttpContentType,
  resolveRequestMtlsMaterial,
  TailnetUnavailableError,
} from "./proxy";
import { SocksProxyAgent } from "socks-proxy-agent";

const forwarderConfig = {
  getUpstreamCa: () => "test-ca",
  getSessionMtlsMaterial: () => undefined,
};

// Creates a minimal request shape so credential-gate behavior can be validated without a live server.
const makeRequest = (headers: Record<string, string> = {}): Request =>
  ({
    params: { splat: "info/refs" },
    url: "/api/git/info/refs?service=git-upload-pack",
    method: "GET",
    headers,
    header: (name: string) => headers[name.toLowerCase()] ?? headers[name] ?? undefined,
  }) as unknown as Request;

// Captures response writes so tests can assert proxy gate failures deterministically.
const makeResponse = () => {
  const response = {
    status: vi.fn().mockReturnThis(),
    json: vi.fn().mockReturnThis(),
    headersSent: false,
  } as unknown as Response;
  return response;
};

// Provides the writable/evented response surface createForwarder needs for stream tests.
class StreamingResponseMock extends Writable {
  public headersSent = false;

  public status = vi.fn().mockReturnThis();

  public json = vi.fn().mockImplementation(() => {
    this.headersSent = true;
    return this;
  });

  public setHeader = vi.fn().mockImplementation(() => this);

  public end = vi.fn().mockImplementation(() => {
    this.headersSent = true;
    super.end();
    return this;
  });

  _write(_chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
    this.headersSent = true;
    callback();
  }
}

const stableProxy = {
  socksAddr: "127.0.0.1:41234",
  socksUsername: "tsnet",
  socksPassword: "deadbeef",
};
const withTailnet = { getTailnetProxy: () => stableProxy };

describe("createMtlsAgentPool", () => {
  const materialA = {
    keyPem: "-----BEGIN PRIVATE KEY-----\nkey-a\n-----END PRIVATE KEY-----\n",
    certPem: "-----BEGIN CERTIFICATE-----\ncert-a\n-----END CERTIFICATE-----\n",
  };
  const materialB = {
    keyPem: "-----BEGIN PRIVATE KEY-----\nkey-b\n-----END PRIVATE KEY-----\n",
    certPem: "-----BEGIN CERTIFICATE-----\ncert-b\n-----END CERTIFICATE-----\n",
  };

  // Reusing agents by identity avoids repeated TLS handshakes for bursty media traffic.
  it("reuses the same agent for identical CA and certificate material", () => {
    const pool = createMtlsAgentPool(withTailnet);
    try {
      const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      const second = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      expect(first).toBeInstanceOf(SocksProxyAgent);
      expect(second).toBe(first);
    } finally {
      pool.destroy();
    }
  });

  // Distinct upstream trust roots must never share sockets to avoid cross-target confusion.
  it("creates different agents when the CA differs", () => {
    const pool = createMtlsAgentPool(withTailnet);
    try {
      const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      const second = pool.acquire({ upstreamCa: "ca-b", mtlsMaterial: materialA });
      expect(second).not.toBe(first);
    } finally {
      pool.destroy();
    }
  });

  // Different client certs represent different identities and must remain isolated.
  it("creates different agents when mTLS material differs", () => {
    const pool = createMtlsAgentPool(withTailnet);
    try {
      const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      const second = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialB });
      expect(second).not.toBe(first);
    } finally {
      pool.destroy();
    }
  });

  // gitd publishes no host port any more, so an agent that dials directly
  // cannot reach it at all. Every upstream connection has to go through the
  // sidecar's SOCKS5 proxy.
  it("dials through the tailnet proxy when one is available", () => {
    const pool = createMtlsAgentPool({
      getTailnetProxy: () => ({
        socksAddr: "127.0.0.1:41234",
        socksUsername: "tsnet",
        socksPassword: "deadbeef",
      }),
    });
    try {
      const agent = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      expect(agent).toBeInstanceOf(SocksProxyAgent);
    } finally {
      pool.destroy();
    }
  });

  // socks5:// resolves gitd.replycant.internal on the host, which has no
  // MagicDNS. socks5h:// sends the name to the sidecar, which is the only
  // resolver that can answer it.
  it("leaves MagicDNS resolution to the sidecar", () => {
    const pool = createMtlsAgentPool({
      getTailnetProxy: () => ({
        socksAddr: "127.0.0.1:41234",
        socksUsername: "tsnet",
        socksPassword: "deadbeef",
      }),
    });
    try {
      const agent = pool.acquire({
        upstreamCa: "ca-a",
        mtlsMaterial: materialA,
      }) as SocksProxyAgent;
      expect(agent.shouldLookup).toBe(false);
    } finally {
      pool.destroy();
    }
  });

  // The mTLS identity and CA pinning from ADR-0011/0013 must hold through the
  // tailnet. The proxy carries ciphertext it cannot read, so TLS still runs
  // end to end with the device certificate and the deployment CA.
  it("keeps the mTLS identity and CA pinning when proxied", () => {
    const pool = createMtlsAgentPool({
      getTailnetProxy: () => ({
        socksAddr: "127.0.0.1:41234",
        socksUsername: "tsnet",
        socksPassword: "deadbeef",
      }),
    });
    try {
      const agent = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA }) as unknown as {
        options: { ca?: string; cert?: string; key?: string; rejectUnauthorized?: boolean };
      };
      expect(agent.options.ca).toBe("ca-a");
      expect(agent.options.cert).toBe(materialA.certPem);
      expect(agent.options.key).toBe(materialA.keyPem);
      expect(agent.options.rejectUnauthorized).toBe(true);
    } finally {
      pool.destroy();
    }
  });

  // gitd is reachable only through the tailnet, so dialling directly while
  // the sidecar is down would only fail later with a confusing DNS error, or
  // worse, reach whatever answers that name on the local network.
  it("refuses to dial while the tailnet is down", () => {
    const pool = createMtlsAgentPool({ getTailnetProxy: () => undefined });
    try {
      expect(() => pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA })).toThrow(
        TailnetUnavailableError,
      );
    } finally {
      pool.destroy();
    }
  });

  // An agent holds sockets already dialled through one specific proxy. After a
  // sidecar restart the old proxy is gone, so reusing the agent would hand out
  // sockets to a port nothing is listening on.
  it("does not reuse an agent across a sidecar restart", () => {
    let proxy = {
      socksAddr: "127.0.0.1:41234",
      socksUsername: "tsnet",
      socksPassword: "first-run",
    };
    const pool = createMtlsAgentPool({ getTailnetProxy: () => proxy });
    try {
      const before = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      proxy = { socksAddr: "127.0.0.1:41999", socksUsername: "tsnet", socksPassword: "second-run" };
      const after = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      expect(after).not.toBe(before);
    } finally {
      pool.destroy();
    }
  });

  // The sidecar comes up after the server does, so the proxy is read on each
  // acquire. Capturing it once would leave the app permanently refusing.
  it("picks up a tailnet proxy that appears after startup", () => {
    let proxy: { socksAddr: string; socksUsername: string; socksPassword: string } | undefined;
    const pool = createMtlsAgentPool({ getTailnetProxy: () => proxy });
    try {
      expect(() => pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA })).toThrow(
        TailnetUnavailableError,
      );
      proxy = { socksAddr: "127.0.0.1:41234", socksUsername: "tsnet", socksPassword: "later" };
      expect(pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA })).toBeInstanceOf(
        SocksProxyAgent,
      );
    } finally {
      pool.destroy();
    }
  });

  // Reuse still has to work while the proxy is stable, or every request would
  // rebuild a SOCKS connection and a TLS handshake.
  it("reuses the proxied agent while the proxy is unchanged", () => {
    const proxy = {
      socksAddr: "127.0.0.1:41234",
      socksUsername: "tsnet",
      socksPassword: "stable",
    };
    const pool = createMtlsAgentPool({ getTailnetProxy: () => proxy });
    try {
      const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      const second = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      expect(second).toBe(first);
    } finally {
      pool.destroy();
    }
  });

  // Bounded keep-alive settings prevent socket spikes while still enabling reuse.
  it("builds agents with bounded keep-alive configuration", () => {
    const pool = createMtlsAgentPool(withTailnet);
    try {
      const agent = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
      expect(agent.keepAlive).toBe(true);
      expect(agent.maxSockets).toBe(32);
      expect(agent.maxFreeSockets).toBe(4);
    } finally {
      pool.destroy();
    }
  });

  // LRU eviction keeps the cache finite so stale identities do not retain resources forever.
  it("evicts and destroys the least-recently-used entry when over capacity", () => {
    const pool = createMtlsAgentPool({ ...withTailnet, maxEntries: 2 });
    const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
    const firstDestroySpy = vi.spyOn(first, "destroy");
    pool.acquire({ upstreamCa: "ca-b", mtlsMaterial: materialA });
    pool.acquire({ upstreamCa: "ca-c", mtlsMaterial: materialA });
    expect(firstDestroySpy).toHaveBeenCalledTimes(1);
  });

  // Explicit destroy lets app shutdown release idle keep-alive sockets immediately.
  it("destroys all cached agents when destroy is called", () => {
    const pool = createMtlsAgentPool(withTailnet);
    const first = pool.acquire({ upstreamCa: "ca-a", mtlsMaterial: materialA });
    const second = pool.acquire({ upstreamCa: "ca-b", mtlsMaterial: materialB });
    const firstDestroySpy = vi.spyOn(first, "destroy");
    const secondDestroySpy = vi.spyOn(second, "destroy");

    pool.destroy();

    expect(firstDestroySpy).toHaveBeenCalledTimes(1);
    expect(secondDestroySpy).toHaveBeenCalledTimes(1);
  });
});

describe("createForwarder", () => {
  it("rejects requests without mTLS headers when required", async () => {
    const forward = createForwarder(forwarderConfig);
    const req = makeRequest();
    const res = makeResponse();
    await forward(req, res, "https://localhost:8443", { requiresMtlsMaterial: true });
    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith({ error: "Missing or invalid request mTLS credentials." });
  });

  it("rejects requests with invalid base64 headers when mTLS is required", async () => {
    const forward = createForwarder(forwarderConfig);
    const req = makeRequest({
      [CLIENT_KEY_HEADER]: "not-base64",
      [CLIENT_CERT_HEADER]: "still-not-base64",
    });
    const res = makeResponse();
    await forward(req, res, "https://localhost:8443", { requiresMtlsMaterial: true });
    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith({ error: "Missing or invalid request mTLS credentials." });
  });

  // Video elements cannot set headers, so header-less media requests must be
  // able to fall back to the identity the browser registered for its session.
  it("accepts header-less requests when session material is available", async () => {
    const forward = createForwarder({
      ...forwarderConfig,
      getSessionMtlsMaterial: () => ({ keyPem: "-----BEGIN PRIVATE KEY-----", certPem: "-----BEGIN CERTIFICATE-----" }),
    });
    const req = makeRequest();
    const res = makeResponse();
    await forward(req, res, "https://localhost:8443", { requiresMtlsMaterial: true });
    expect(res.status).not.toHaveBeenCalledWith(401);
  });

  // Mirrors the iOS router's "not connected yet": a request made while the
  // sidecar is still joining gets a clear, retryable answer instead of a
  // generic upstream failure.
  it("answers 503 while the tailnet is down", async () => {
    const forward = createForwarder({ ...forwarderConfig, getTailnetProxy: () => undefined });
    const req = makeRequest({
      [CLIENT_KEY_HEADER]: Buffer.from("-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n").toString("base64"),
      [CLIENT_CERT_HEADER]: Buffer.from("-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n").toString("base64"),
    });
    const res = makeResponse();
    await forward(req, res, "https://gitd.replycant.internal:8443", { requiresMtlsMaterial: true });
    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({ error: "Not connected to your library's network yet." });
  });

  it("rejects header-less requests when no session material is registered", async () => {
    const forward = createForwarder(forwarderConfig);
    const req = makeRequest();
    const res = makeResponse();
    await forward(req, res, "https://localhost:8443", { requiresMtlsMaterial: true });
    expect(res.status).toHaveBeenCalledWith(401);
  });

  // Aborting downstream playback should promptly release the proxy's upstream socket.
  it("destroys the upstream request when the client disconnects mid-stream", async () => {
    let originSocketClosedResolve: (() => void) | null = null;
    const originSocketClosed = new Promise<void>((resolve) => {
      originSocketClosedResolve = resolve;
    });
    const upstreamServer = createServer((req, res) => {
      req.socket.once("close", () => originSocketClosedResolve?.());
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.write("chunk");
      // Keep the stream open to mimic long-running media responses.
    });
    const requestSeen = once(upstreamServer, "request");
    await new Promise<void>((resolve) => upstreamServer.listen(0, "127.0.0.1", resolve));
    try {
      const address = upstreamServer.address();
      if (!address || typeof address === "string") {
        throw new Error("Expected numeric upstream address.");
      }
      const forward = createForwarder(forwarderConfig);
      const req = makeRequest({
        [CLIENT_KEY_HEADER]: Buffer.from("-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n").toString("base64"),
        [CLIENT_CERT_HEADER]: Buffer.from("-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n").toString("base64"),
      });
      const res = new StreamingResponseMock() as unknown as Response;

      await forward(req, res, `http://127.0.0.1:${address.port}`, { requiresMtlsMaterial: true });
      await requestSeen;
      (res as unknown as StreamingResponseMock).emit("close");
      await originSocketClosed;
    } finally {
      await new Promise<void>((resolve, reject) => {
        upstreamServer.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    }
  });

  // Completed responses should not be treated as disconnect failures.
  it("does not emit proxy errors for normally completed responses", async () => {
    const upstreamServer = createServer((_req, res) => {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.end("done");
    });
    const requestSeen = once(upstreamServer, "request");
    await new Promise<void>((resolve) => upstreamServer.listen(0, "127.0.0.1", resolve));
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const address = upstreamServer.address();
      if (!address || typeof address === "string") {
        throw new Error("Expected numeric upstream address.");
      }
      const forward = createForwarder(forwarderConfig);
      const req = makeRequest({
        [CLIENT_KEY_HEADER]: Buffer.from("-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n").toString("base64"),
        [CLIENT_CERT_HEADER]: Buffer.from("-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n").toString("base64"),
      });
      const res = new StreamingResponseMock() as unknown as Response;

      await forward(req, res, `http://127.0.0.1:${address.port}`, { requiresMtlsMaterial: true });
      await requestSeen;
      await once(res as unknown as StreamingResponseMock, "finish");

      expect((res as unknown as StreamingResponseMock).status).not.toHaveBeenCalledWith(502);
      expect(errorSpy).not.toHaveBeenCalledWith(expect.stringContaining("[proxy] upstream connection error"));
    } finally {
      errorSpy.mockRestore();
      await new Promise<void>((resolve, reject) => {
        upstreamServer.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    }
  });
});

describe("resolveRequestMtlsMaterial", () => {
  const keyPem = "-----BEGIN PRIVATE KEY-----\nheader-key\n-----END PRIVATE KEY-----\n";
  const certPem = "-----BEGIN CERTIFICATE-----\nheader-cert\n-----END CERTIFICATE-----\n";

  // Per-request headers must win so a shared proxy never misattributes a
  // request that already carries its own identity.
  it("prefers per-request headers over session material", () => {
    const req = makeRequest({
      [CLIENT_KEY_HEADER]: Buffer.from(keyPem).toString("base64"),
      [CLIENT_CERT_HEADER]: Buffer.from(certPem).toString("base64"),
    });
    const resolved = resolveRequestMtlsMaterial(req, () => ({ keyPem: "session-key", certPem: "session-cert" }));
    expect(resolved?.certPem).toBe(certPem);
  });

  it("falls back to session material when headers are absent", () => {
    const resolved = resolveRequestMtlsMaterial(makeRequest(), () => ({
      keyPem: "session-key",
      certPem: "session-cert",
    }));
    expect(resolved?.keyPem).toBe("session-key");
  });

  it("returns null when neither source provides material", () => {
    expect(resolveRequestMtlsMaterial(makeRequest(), () => undefined)).toBeNull();
  });
});

describe("git content-type guard helpers", () => {
  it("accepts supported git smart-http response content types", () => {
    expect(isGitSmartHttpContentType("application/x-git-upload-pack-advertisement")).toBe(true);
    expect(isGitSmartHttpContentType("application/x-git-upload-pack-result; charset=utf-8")).toBe(true);
    expect(isGitSmartHttpContentType("application/x-git-receive-pack-advertisement")).toBe(true);
    expect(isGitSmartHttpContentType("application/x-git-receive-pack-result")).toBe(true);
  });

  it("rejects non-git response content types", () => {
    expect(isGitSmartHttpContentType("application/json")).toBe(false);
    expect(isGitSmartHttpContentType("text/plain")).toBe(false);
    expect(isGitSmartHttpContentType("")).toBe(false);
  });

  it("formats deterministic mismatch diagnostics", () => {
    expect(describeGitSmartHttpMismatch(200, "text/html")).toBe(
      "Expected git smart-HTTP response but got status=200 content-type=text/html.",
    );
    expect(describeGitSmartHttpMismatch(200, "")).toBe(
      "Expected git smart-HTTP response but got status=200 content-type=missing.",
    );
  });
});

describe("filterProxyResponseHeaders", () => {
  it("drops hop-by-hop response headers", () => {
    const filtered = filterProxyResponseHeaders({
      connection: "keep-alive",
      "transfer-encoding": "chunked",
      "content-type": "application/json",
      "content-length": "12",
    });
    expect(filtered).toEqual([
      ["content-type", "application/json"],
      ["content-length", "12"],
    ]);
  });

  it("drops explicitly blocked headers", () => {
    const filtered = filterProxyResponseHeaders(
      {
        "content-type": "application/vnd.apple.mpegurl",
        "content-length": "999",
        "content-encoding": "gzip",
      },
      ["content-length", "content-encoding"],
    );
    expect(filtered).toEqual([["content-type", "application/vnd.apple.mpegurl"]]);
  });
});

describe("buildForwardedResponseHeaders", () => {
  it("drops content-length for chunked git smart-http streams", () => {
    const headers = buildForwardedResponseHeaders(
      {
        "content-type": "application/x-git-upload-pack-result",
        "content-length": "1024",
        "transfer-encoding": "chunked",
      },
      { expectsGitSmartHttp: true },
    );
    expect(headers).toEqual([["content-type", "application/x-git-upload-pack-result"]]);
  });

  it("preserves content-length for non-chunked git smart-http streams", () => {
    const headers = buildForwardedResponseHeaders(
      {
        "content-type": "application/x-git-upload-pack-result",
        "content-length": "1024",
      },
      { expectsGitSmartHttp: true },
    );
    expect(headers).toEqual([
      ["content-type", "application/x-git-upload-pack-result"],
      ["content-length", "1024"],
    ]);
  });
});
