import request from "supertest";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createApp, Forwarder } from "./app";
import { ProxyConfig } from "./config";
import { CLIENT_CERT_HEADER, CLIENT_KEY_HEADER } from "./proxy";
import { createSetupState } from "./setupState";

const proxyConfig: ProxyConfig = {
  gitBaseUrl: "https://localhost:8443",
  transcodedBaseUrl: "https://localhost:8443/transcoded",
  decryptdBaseUrl: "https://localhost:8443/decryptd",
  port: 8787,
  upstreamCa: "test-ca",
};

// Matches the payload the browser sends after unlocking its identity.
const mtlsSessionPayload = {
  [CLIENT_KEY_HEADER]: Buffer.from("-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n").toString("base64"),
  [CLIENT_CERT_HEADER]: Buffer.from("-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n").toString(
    "base64",
  ),
};

// Captures route forwarding behavior so proxy path regressions are caught early.
const createForwarderMock = () => {
  const fn: Forwarder = async (_req, res) => {
    res.status(200).json({ ok: true });
  };
  return vi.fn(fn);
};

describe("createApp", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("serves health endpoint", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    const res = await request(app).get("/api/health");
    expect(res.status).toBe(200);
    expect(res.body.status).toBe("ok");
    expect(forward).not.toHaveBeenCalled();
  });

  it("forwards git route to git base URL", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    await request(app).post("/api/git/info/refs?service=git-upload-pack");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe(proxyConfig.gitBaseUrl);
    expect(forward.mock.calls[0]?.[3]).toEqual({ requiresMtlsMaterial: true, expectsGitSmartHttp: true });
  });

  it("forwards lfs route with forceLfsAccept", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    await request(app).get("/api/lfs/objects/abc123");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe("https://localhost:8443/lfs");
    expect(forward.mock.calls[0]?.[3]).toEqual({ forceLfsAccept: true, requiresMtlsMaterial: true });
  });

  it("forwards transcoded route to transcoded base URL", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    await request(app).get("/api/transcoded/hls/hash/10/playlist.m3u8");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe(proxyConfig.transcodedBaseUrl);
    expect(forward.mock.calls[0]?.[3]).toEqual({ requiresMtlsMaterial: true });
  });

  // Keeps generic transcoded routes proxied directly now that HEIC server fallback has been removed.
  it("forwards original transcoded path through proxy", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    await request(app).get(`/api/transcoded/original/${"a".repeat(64)}.jpg`);
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe(proxyConfig.transcodedBaseUrl);
    expect(forward.mock.calls[0]?.[3]).toEqual({ requiresMtlsMaterial: true });
  });

  it("derives transcoded route base URL as a gitd route from the runtime git origin", async () => {
    const forward = createForwarderMock();
    const app = createApp(
      { ...proxyConfig, transcodedBaseUrl: undefined },
      forward,
      createSetupState({ gitBaseUrl: "https://git.runtime.example:8443", lfsBaseUrl: "https://git.runtime.example:8443/lfs", upstreamCa: "ca" }),
    );
    await request(app).get("/api/transcoded/hls/hash/10/playlist.m3u8");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe("https://git.runtime.example:8443/transcoded");
    expect(forward.mock.calls[0]?.[3]).toEqual({ requiresMtlsMaterial: true });
  });

  it("forwards decryptd route to decryptd base URL with decryption headers", async () => {
    const forward = createForwarderMock();
    const app = createApp(proxyConfig, forward);
    await request(app).get("/api/decryptd/objects/hash123?dek=base64dek");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe(proxyConfig.decryptdBaseUrl);
    expect(forward.mock.calls[0]?.[3]).toEqual({ requiresMtlsMaterial: true });
    const forwardedReq = forward.mock.calls[0]?.[0];
    expect(forwardedReq.headers["x-replycant-dek"]).toBe("base64dek");
    expect(forwardedReq.headers["x-replycant-chunk-size"]).toBeUndefined();
    expect(forwardedReq.url).toBe("/api/decryptd/objects/hash123");
  });

  it("derives decryptd route base URL as a gitd route from the runtime git origin", async () => {
    const forward = createForwarderMock();
    const app = createApp(
      { ...proxyConfig, decryptdBaseUrl: undefined },
      forward,
      createSetupState({ gitBaseUrl: "https://git.runtime.example:8443", lfsBaseUrl: "https://git.runtime.example:8443/lfs", upstreamCa: "ca" }),
    );
    await request(app).get("/api/decryptd/objects/hash123?dek=base64dek");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe("https://git.runtime.example:8443/decryptd");
  });

  // Media elements cannot attach the per-request mTLS headers, so the browser
  // registers its identity once and the proxy scopes it to a session cookie.
  it("stores mTLS material against a session cookie", async () => {
    const setupState = createSetupState();
    const app = createApp(proxyConfig, createForwarderMock(), setupState);

    const res = await request(app).post("/api/setup/session").send(mtlsSessionPayload);

    expect(res.status).toBe(204);
    const cookies = res.headers["set-cookie"] as unknown as string[];
    const sessionCookie = cookies.find((cookie) => cookie.startsWith("replycant.session="));
    expect(sessionCookie).toBeDefined();
    expect(sessionCookie).toContain("HttpOnly");

    const sessionId = sessionCookie!.split(";")[0]!.split("=")[1]!;
    expect(setupState.getSessionMtlsMaterial(sessionId)?.certPem).toContain("BEGIN CERTIFICATE");
  });

  it("rejects session registration with malformed mTLS material", async () => {
    const app = createApp(proxyConfig, createForwarderMock(), createSetupState());

    const res = await request(app).post("/api/setup/session").send({
      [CLIENT_KEY_HEADER]: "not-base64-pem",
      [CLIENT_CERT_HEADER]: "also-not-a-cert",
    });

    expect(res.status).toBe(400);
    expect(res.headers["set-cookie"]).toBeUndefined();
  });

  it("issues distinct sessions so concurrent browsers keep separate identities", async () => {
    const setupState = createSetupState();
    const app = createApp(proxyConfig, createForwarderMock(), setupState);

    const first = await request(app).post("/api/setup/session").send(mtlsSessionPayload);
    const second = await request(app)
      .post("/api/setup/session")
      .send({
        ...mtlsSessionPayload,
        [CLIENT_CERT_HEADER]: Buffer.from(
          "-----BEGIN CERTIFICATE-----\nother\n-----END CERTIFICATE-----\n",
        ).toString("base64"),
      });

    const readSessionId = (res: request.Response) =>
      (res.headers["set-cookie"] as unknown as string[])[0]!.split(";")[0]!.split("=")[1]!;

    const firstId = readSessionId(first);
    const secondId = readSessionId(second);
    expect(firstId).not.toBe(secondId);
    expect(setupState.getSessionMtlsMaterial(firstId)?.certPem).toContain("cert");
    expect(setupState.getSessionMtlsMaterial(secondId)?.certPem).toContain("other");
  });

  it("returns 503 for git requests before setup configuration", async () => {
    const forward = createForwarderMock();
    const app = createApp(
      { ...proxyConfig, gitBaseUrl: undefined, upstreamCa: undefined },
      forward,
      createSetupState(),
    );
    const res = await request(app).get("/api/git/info/refs?service=git-upload-pack");
    expect(res.status).toBe(503);
    expect(forward).not.toHaveBeenCalled();
  });

  it("discovers config from caserver endpoint", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ ca: "ca", url: "https://git.example" }),
      }),
    );
    const app = createApp(proxyConfig, createForwarderMock());
    const res = await request(app).post("/api/setup/discover").send({ serverUrl: "http://replycant.local:8080" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ca: "ca", url: "https://git.example" });
  });

  // Verifies that Node fetch's opaque "fetch failed" gets unwrapped to the
  // underlying cause (e.g. ENOTFOUND, ECONNREFUSED) so the client can show
  // an actionable error.
  it("returns root cause in discover detail when fetch throws with cause", async () => {
    const cause = new Error("getaddrinfo ENOTFOUND replycant.local");
    const fetchError = new Error("fetch failed");
    fetchError.cause = cause;
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(fetchError));
    const app = createApp(proxyConfig, createForwarderMock());
    const res = await request(app).post("/api/setup/discover").send({ serverUrl: "http://replycant.local:8080" });
    expect(res.status).toBe(502);
    expect(res.body.detail).toBe("getaddrinfo ENOTFOUND replycant.local");
  });

  it("rejects invalid discover request payloads", async () => {
    const app = createApp(proxyConfig, createForwarderMock());
    const res = await request(app).post("/api/setup/discover").send({ serverUrl: "not-a-url" });
    expect(res.status).toBe(400);
  });

  it("returns 502 when discover response payload is invalid", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ wrong: "shape" }),
      }),
    );
    const app = createApp(proxyConfig, createForwarderMock());
    const res = await request(app).post("/api/setup/discover").send({ serverUrl: "http://replycant.local:8080" });
    expect(res.status).toBe(502);
  });

  it("configures runtime setup and forwards git route", async () => {
    const forward = createForwarderMock();
    const setupState = createSetupState();
    const app = createApp(
      { ...proxyConfig, gitBaseUrl: undefined, upstreamCa: undefined },
      forward,
      setupState,
    );
    const configureRes = await request(app)
      .post("/api/setup/configure")
      .send({ ca: "ca", url: "https://git.runtime.example" });
    expect(configureRes.status).toBe(204);

    await request(app).post("/api/git/info/refs?service=git-upload-pack");
    expect(forward).toHaveBeenCalledTimes(1);
    expect(forward.mock.calls[0]?.[2]).toBe("https://git.runtime.example");
  });
});
