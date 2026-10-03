import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearTailnetConfigRecord,
  gitdControlAddr,
  GITD_TAILNET_PORT,
  gitdTailnetUrl,
  joinTailnet,
  loadTailnetConfigRecord,
  saveTailnetConfigRecord,
  TAILNET_CONFIG_STORAGE_KEY,
  tailnetSupported,
  toHeadscaleAddr,
  toTailnetConfigRecord,
} from "./tailnet";
import type { PairingPayload } from "./pairing";

const payload: PairingPayload = {
  headscaleUrl: "https://abc123.tunnel.replycant.com",
  caPem: "-----BEGIN CERTIFICATE-----ca-----END CERTIFICATE-----",
};

// Only the first device's join carries a key, from the CA page.
const firstDeviceKey = "preauth-abc";

const identity = {
  privateKeyPem: "-----BEGIN PRIVATE KEY-----k",
  certificatePem: "-----BEGIN CERTIFICATE-----c",
  deviceName: "Ante's Laptop",
};

afterEach(() => {
  localStorage.clear();
  delete (window as { replycantDesktop?: unknown }).replycantDesktop;
});

describe("toHeadscaleAddr", () => {
  // The sidecar dials a host and port because it speaks TLS straight to
  // hsproxy; the URL form only exists because that is how headscale advertises
  // itself.
  it("defaults an https URL to port 443", () => {
    expect(toHeadscaleAddr("https://abc.tunnel.replycant.com")).toEqual({
      addr: "abc.tunnel.replycant.com:443",
      serverName: "abc.tunnel.replycant.com",
    });
  });

  // Manual-exposure deployments forward an arbitrary router port, so an
  // explicit port has to survive.
  it("keeps an explicit port", () => {
    expect(toHeadscaleAddr("https://headscale.example.com:8443").addr).toBe(
      "headscale.example.com:8443",
    );
  });

  it("defaults an http URL to port 80", () => {
    expect(toHeadscaleAddr("http://headscale.example.com").addr).toBe("headscale.example.com:80");
  });

  // The server name is pinned separately from the dial target, because TLS has
  // to be verified against the hostname even when the address is not one.
  it("reports the hostname separately from the dial target", () => {
    expect(toHeadscaleAddr("https://headscale.example.com:8443").serverName).toBe(
      "headscale.example.com",
    );
  });

  it("rejects a URL it cannot parse", () => {
    expect(() => toHeadscaleAddr("headscale.example.com")).toThrow(/not a valid URL/);
  });
});

describe("gitdTailnetUrl", () => {
  // MagicDNS resolves this inside the tailnet and gitd's certificate carries
  // the matching SAN, which is what lets the existing mTLS transport work
  // unchanged over the tailnet.
  it("builds the MagicDNS URL for gitd", () => {
    expect(gitdTailnetUrl()).toBe("https://gitd.replycant.internal:8443");
  });

  // gitd's tailnet listener is not on 443, and the headscale policy only opens
  // the ports gitd actually serves, so an implied port would be denied by the
  // tailnet before it ever reached gitd.
  it("names the port gitd serves on rather than implying 443", () => {
    expect(gitdTailnetUrl()).toContain(`:${GITD_TAILNET_PORT}`);
  });
});

describe("gitdControlAddr", () => {
  // The in-tailnet control path is what lets a paired device stop depending on
  // the hosted relay, so the sidecar has to be told where it is.
  it("targets gitd's control relay by MagicDNS name", () => {
    expect(gitdControlAddr()).toEqual({
      addr: "gitd.replycant.internal:8444",
      serverName: "gitd.replycant.internal",
    });
  });

  // hsproxy presents one certificate covering both the tunnel hostname and the
  // tailnet name, so the name verified on this path is the tailnet one.
  it("verifies the tailnet name rather than the tunnel hostname", () => {
    const { serverName } = gitdControlAddr();
    expect(serverName).not.toContain("tunnel");
  });
});

describe("tailnet config persistence", () => {
  it("round-trips a record", () => {
    const record = toTailnetConfigRecord(payload);
    saveTailnetConfigRecord(record);
    expect(loadTailnetConfigRecord()).toEqual(record);
  });

  it("derives the record from a pairing payload", () => {
    expect(toTailnetConfigRecord(payload)).toEqual({
      headscaleAddr: "abc123.tunnel.replycant.com:443",
      headscaleServerName: "abc123.tunnel.replycant.com",
    });
  });

  it("reports no record before pairing", () => {
    expect(loadTailnetConfigRecord()).toBeNull();
  });

  // A corrupted entry must degrade to "not on a tailnet" rather than blocking
  // startup, since the LAN path may still work.
  it("treats unparseable storage as no record", () => {
    localStorage.setItem(TAILNET_CONFIG_STORAGE_KEY, "{not json");
    expect(loadTailnetConfigRecord()).toBeNull();
  });

  it("treats a record with missing fields as no record", () => {
    localStorage.setItem(TAILNET_CONFIG_STORAGE_KEY, JSON.stringify({ headscaleAddr: "a:443" }));
    expect(loadTailnetConfigRecord()).toBeNull();
  });

  it("clears the record", () => {
    saveTailnetConfigRecord(toTailnetConfigRecord(payload));
    clearTailnetConfigRecord();
    expect(loadTailnetConfigRecord()).toBeNull();
  });
});

describe("tailnetSupported", () => {
  // Joining means running a userspace WireGuard node, which needs a native
  // binary the browser build cannot host, so the browser stays on the LAN path.
  it("is false in a plain browser", () => {
    expect(tailnetSupported()).toBe(false);
  });

  it("is true when the desktop shell exposes the bridge", () => {
    (window as { replycantDesktop?: unknown }).replycantDesktop = {
      joinTailnet: vi.fn(),
    };
    expect(tailnetSupported()).toBe(true);
  });
});

describe("joinTailnet", () => {
  let joinTailnetBridge: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    joinTailnetBridge = vi.fn().mockResolvedValue(undefined);
    (window as { replycantDesktop?: unknown }).replycantDesktop = {
      joinTailnet: joinTailnetBridge,
    };
  });

  // The device presents the certificate it already uses for gitd, because
  // hsproxy authorizes by public key rather than by chain. Sending a different
  // credential would mean revocation had two places to reach.
  it("presents the device's existing gitd identity", async () => {
    await joinTailnet({
      record: toTailnetConfigRecord(payload),
      caPem: payload.caPem,
      identity,
      preauthKey: firstDeviceKey,
    });

    expect(joinTailnetBridge).toHaveBeenCalledWith({
      headscaleAddr: "abc123.tunnel.replycant.com:443",
      headscaleServerName: "abc123.tunnel.replycant.com",
      gitdControlAddr: "gitd.replycant.internal:8444",
      gitdControlServerName: "gitd.replycant.internal",
      caPem: payload.caPem,
      clientCertPem: identity.certificatePem,
      clientKeyPem: identity.privateKeyPem,
      preauthKey: "preauth-abc",
      hostname: "Ante's Laptop",
    });
  });

  // A paired device, and any rejoin after restart, has no key to offer and
  // must not send an empty one: the sidecar would try to register with it
  // instead of minting its own.
  it("omits the pre-auth key when there is none", async () => {
    await joinTailnet({
      record: toTailnetConfigRecord(payload),
      caPem: payload.caPem,
      identity,
    });

    expect(joinTailnetBridge.mock.calls[0]?.[0]).not.toHaveProperty("preauthKey");
  });

  // The browser build reaching this point is a bug, but the user should read an
  // instruction rather than a property access failure.
  it("explains itself when the bridge is absent", async () => {
    delete (window as { replycantDesktop?: unknown }).replycantDesktop;

    await expect(
      joinTailnet({ record: toTailnetConfigRecord(payload), caPem: payload.caPem, identity }),
    ).rejects.toThrow(/desktop app/);
  });
});
