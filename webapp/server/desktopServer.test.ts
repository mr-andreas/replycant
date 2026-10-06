import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SocksProxyAgent } from "socks-proxy-agent";
import { ProxyConfig } from "./config";
import { startDesktopServer, DesktopServer } from "./desktopServer";
import * as proxyModule from "./proxy";

const proxyConfig: ProxyConfig = {
  gitBaseUrl: undefined,
  transcodedBaseUrl: "http://localhost:8082",
  port: 8787,
  upstreamCa: undefined,
};

const activeServers: DesktopServer[] = [];
const tempDirs: string[] = [];

// Creates an isolated static asset directory so desktop fallback routing can be validated safely.
const createStaticDir = (): string => {
  const path = mkdtempSync(join(tmpdir(), "replycant-desktop-"));
  tempDirs.push(path);
  writeFileSync(join(path, "index.html"), "<!doctype html><html><body>desktop</body></html>", "utf8");
  return path;
};

describe("startDesktopServer", () => {
  afterEach(async () => {
    vi.restoreAllMocks();
    while (activeServers.length > 0) {
      const server = activeServers.pop();
      if (server) {
        await server.close();
      }
    }
    while (tempDirs.length > 0) {
      const path = tempDirs.pop();
      if (path) {
        rmSync(path, { recursive: true, force: true });
      }
    }
  });

  it("serves API health checks on loopback", async () => {
    const server = await startDesktopServer({
      config: proxyConfig,
      staticDir: createStaticDir(),
      getTailnetProxy: () => undefined,
    });
    activeServers.push(server);
    expect(server.url.startsWith("http://127.0.0.1:")).toBe(true);
    const res = await request(server.server).get("/api/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });

  it("falls back to index.html for non-api routes", async () => {
    const server = await startDesktopServer({
      config: proxyConfig,
      staticDir: createStaticDir(),
      getTailnetProxy: () => undefined,
    });
    activeServers.push(server);
    const res = await request(server.server).get("/timeline");
    expect(res.status).toBe(200);
    expect(res.text).toContain("desktop");
  });

  // desktop:dev starts this server so `/api/git` shares the sidecar SOCKS
  // pool. If getTailnetProxy is ignored, Vite's 502 is just moved here.
  it("dials upstream through the supplied tailnet proxy", async () => {
    const createPool = vi.spyOn(proxyModule, "createMtlsAgentPool");
    const server = await startDesktopServer({
      config: proxyConfig,
      staticDir: createStaticDir(),
      getTailnetProxy: () => ({
        socksAddr: "127.0.0.1:41234",
        socksUsername: "tsnet",
        socksPassword: "deadbeef",
      }),
    });
    activeServers.push(server);

    expect(createPool).toHaveBeenCalled();
    const pool = createPool.mock.results.at(-1)?.value as
      | proxyModule.MtlsAgentPool
      | undefined;
    expect(pool).toBeDefined();
    const agent = pool?.acquire({
      upstreamCa: "ca-a",
      mtlsMaterial: {
        keyPem: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n",
        certPem: "-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n",
      },
    });
    expect(agent).toBeInstanceOf(SocksProxyAgent);
    agent?.destroy();
  });
});

