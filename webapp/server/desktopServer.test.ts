import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import request from "supertest";
import { afterEach, describe, expect, it } from "vitest";
import { ProxyConfig } from "./config";
import { startDesktopServer, DesktopServer } from "./desktopServer";

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
    });
    activeServers.push(server);
    const res = await request(server.server).get("/timeline");
    expect(res.status).toBe(200);
    expect(res.text).toContain("desktop");
  });
});
