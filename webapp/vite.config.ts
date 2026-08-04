import { defineConfig, type Plugin, type ViteDevServer } from "vite";
import react from "@vitejs/plugin-react";
import { createApp } from "./server/app";
import { loadProxyConfig } from "./server/config";

// Reads Vite CLI flags so explicit `vite --port` launches override env defaults.
const resolveCliPort = (argv: string[]): number | undefined => {
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token) continue;
    if (token.startsWith("--port=")) {
      const parsedInline = Number(token.slice("--port=".length));
      if (Number.isFinite(parsedInline) && parsedInline > 0) return parsedInline;
      continue;
    }
    if (token === "--port") {
      const parsedNext = Number(argv[index + 1]);
      if (Number.isFinite(parsedNext) && parsedNext > 0) return parsedNext;
      continue;
    }
  }
  return undefined;
};

const devServerPort = resolveCliPort(process.argv) ?? Number(process.env.VITE_PORT ?? 5173);

// Mounts the shared API app so Vite dev serves UI and `/api/*` on one origin.
const devApiMiddlewarePlugin = (): Plugin => ({
  name: "replycant-dev-api-middleware",
  configureServer(server: ViteDevServer) {
    server.middlewares.use(createApp(loadProxyConfig()));
  },
});

// Provides one dev origin for UI + API so browser-origin routing stays stable
// regardless of custom Vite ports.
export default defineConfig({
  plugins: [react(), devApiMiddlewarePlugin()],
  worker: {
    format: "es",
  },
  server: {
    host: true,
    allowedHosts: true,
    port: devServerPort,
  },
});
