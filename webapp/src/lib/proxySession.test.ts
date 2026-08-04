import { beforeEach, describe, expect, it, vi } from "vitest";
import { ensureProxySession, resetProxySession } from "./proxySession";

const mtlsHeaders = {
  "x-replycant-client-key": "a2V5",
  "x-replycant-client-cert": "Y2VydA==",
};

describe("ensureProxySession", () => {
  beforeEach(() => {
    resetProxySession();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));
  });

  it("registers the browser identity so media element requests can authenticate", async () => {
    await ensureProxySession(mtlsHeaders);

    expect(fetch).toHaveBeenCalledWith("/api/setup/session", {
      method: "POST",
      headers: { "content-type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(mtlsHeaders),
    });
  });

  // Every fullscreen video open would otherwise re-post the private key.
  it("registers only once per identity", async () => {
    await ensureProxySession(mtlsHeaders);
    await ensureProxySession(mtlsHeaders);

    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("re-registers after a reset so a restarted proxy can recover", async () => {
    await ensureProxySession(mtlsHeaders);
    resetProxySession();
    await ensureProxySession(mtlsHeaders);

    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("re-registers when the identity changes", async () => {
    await ensureProxySession(mtlsHeaders);
    await ensureProxySession({ ...mtlsHeaders, "x-replycant-client-cert": "b3RoZXI=" });

    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("does nothing without unlocked identity material", async () => {
    await ensureProxySession(null);

    expect(fetch).not.toHaveBeenCalled();
  });

  // A failed registration must not be cached, or playback would stay broken
  // until reload even after the proxy recovers.
  it("does not cache failed registrations", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 503 }));

    await expect(ensureProxySession(mtlsHeaders)).rejects.toThrow();
    await expect(ensureProxySession(mtlsHeaders)).rejects.toThrow();

    expect(fetch).toHaveBeenCalledTimes(2);
  });
});
