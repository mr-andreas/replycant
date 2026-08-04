import express from "express";
import { createServer, Server as HttpServer } from "node:http";
import { resolve } from "node:path";
import { createApp } from "./app";
import { loadProxyConfig, ProxyConfig } from "./config";
import { createMtlsAgentPool } from "./proxy";

export interface DesktopServer {
  server: HttpServer;
  port: number;
  url: string;
  close: () => Promise<void>;
}

export interface StartDesktopServerOptions {
  config?: ProxyConfig;
  host?: string;
  port?: number;
  staticDir?: string;
}

// Starts a loopback-only server so the Electron renderer can use the same HTTP origin contract as the web app.
export const startDesktopServer = async ({
  config = loadProxyConfig(),
  host = "127.0.0.1",
  port = 0,
  staticDir = resolve(process.cwd(), "dist"),
}: StartDesktopServerOptions = {}): Promise<DesktopServer> => {
  // Owns the upstream keep-alive pool so desktop shutdown can release sockets deterministically.
  const agentPool = createMtlsAgentPool();
  const app = createApp(config, undefined, undefined, agentPool);
  app.use(express.static(staticDir));
  app.get("/{*splat}", (req, res, next) => {
    if (req.path.startsWith("/api/")) {
      next();
      return;
    }
    res.sendFile(resolve(staticDir, "index.html"));
  });
  const server = createServer(app);
  await new Promise<void>((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(port, host, () => {
      server.off("error", rejectPromise);
      resolvePromise();
    });
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Desktop server failed to expose a numeric port.");
  }
  const resolvedPort = address.port;
  const url = `http://${host}:${resolvedPort}`;
  return {
    server,
    port: resolvedPort,
    url,
    close: () =>
      new Promise<void>((resolveClose, rejectClose) => {
        agentPool.destroy();
        server.close((error) => {
          if (error) {
            rejectClose(error);
            return;
          }
          resolveClose();
        });
      }),
  };
};
