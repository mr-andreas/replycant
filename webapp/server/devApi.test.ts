import { describe, expect, it } from "vitest";
import { resolveDesktopApiListenPort, resolveDevApiMode } from "./devApi";

describe("resolveDevApiMode", () => {
  // Browser `npm run dev` has no Electron sidecar, so Vite must keep serving
  // `/api` itself rather than waiting for a desktop process that will never
  // start.
  it("uses the in-process app when the desktop API env is unset", () => {
    expect(resolveDevApiMode({})).toEqual({ mode: "in-process" });
  });

  it("uses the in-process app when the desktop API env is blank", () => {
    expect(resolveDevApiMode({ REPLYCANT_DESKTOP_API: "  " })).toEqual({
      mode: "in-process",
    });
  });

  // desktop:dev joins the tailnet in Electron. Vite has to proxy `/api` there
  // so gitd.replycant.internal is reached through the sidecar SOCKS pool
  // instead of the host resolver.
  it("proxies to the desktop API when the env is set", () => {
    expect(
      resolveDevApiMode({ REPLYCANT_DESKTOP_API: "http://127.0.0.1:5181" }),
    ).toEqual({ mode: "proxy", target: "http://127.0.0.1:5181" });
  });
});

describe("resolveDesktopApiListenPort", () => {
  // A missing or mistyped env would otherwise bind port 0 and Vite would
  // proxy to a listener that is not there.
  it("reads the explicit port from the desktop API URL", () => {
    expect(resolveDesktopApiListenPort("http://127.0.0.1:5181")).toBe(5181);
  });

  it("rejects a missing desktop API URL", () => {
    expect(() => resolveDesktopApiListenPort(undefined)).toThrow(
      /REPLYCANT_DESKTOP_API/,
    );
  });

  it("rejects a desktop API URL without an explicit port", () => {
    expect(() => resolveDesktopApiListenPort("http://127.0.0.1")).toThrow(
      /explicit port/,
    );
  });

  it("rejects a desktop API value that is not a URL", () => {
    expect(() => resolveDesktopApiListenPort("not-a-url")).toThrow(/valid URL/);
  });
});
