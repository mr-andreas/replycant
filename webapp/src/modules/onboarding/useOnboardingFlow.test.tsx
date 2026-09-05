import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOnboardingFlow } from "./useOnboardingFlow";
import { SETUP_CONFIG_STORAGE_KEY } from "../../lib/config";
import { TAILNET_CONFIG_STORAGE_KEY } from "../../lib/tailnet";
import pairingFixture from "../../lib/pairing.fixture.json";

const gitdbMocks = vi.hoisted(() => ({
  mockLoadIdentityRecord: vi.fn(),
  mockClearIdentityRecord: vi.fn(),
  mockUnlockIdentity: vi.fn(),
  mockCreateIdentity: vi.fn(),
  mockSaveIdentityRecord: vi.fn(),
  mockGetDefaultDeviceName: vi.fn(),
  mockSanitizeDeviceName: vi.fn(),
  mockBuildMtlsHeaders: vi.fn(),
  mockComputeCaHash: vi.fn(),
}));

// The pairing record in the fixture was produced by the Go writer, so the
// tailnet tests below exercise the real decryption path. Only the two
// non-deterministic inputs are stubbed: the freshly minted secret, which has to
// be the one the fixture was sealed under, and the discovery poll, which would
// otherwise reach the network.
const pairingMocks = vi.hoisted(() => ({
  mockPollForPairingRecord: vi.fn(),
  mockCreatePairingSecret: vi.fn(),
}));

vi.mock("../../lib/discovery", () => ({
  pollForPairingRecord: pairingMocks.mockPollForPairingRecord,
}));

vi.mock("../../lib/pairing", async () => {
  const actual = await vi.importActual<typeof import("../../lib/pairing")>("../../lib/pairing");
  return { ...actual, createPairingSecret: pairingMocks.mockCreatePairingSecret };
});

vi.mock("../gitdb", () => ({
  loadIdentityRecord: gitdbMocks.mockLoadIdentityRecord,
  clearIdentityRecord: gitdbMocks.mockClearIdentityRecord,
  unlockIdentity: gitdbMocks.mockUnlockIdentity,
  createIdentity: gitdbMocks.mockCreateIdentity,
  saveIdentityRecord: gitdbMocks.mockSaveIdentityRecord,
  getDefaultDeviceName: gitdbMocks.mockGetDefaultDeviceName,
  sanitizeDeviceName: gitdbMocks.mockSanitizeDeviceName,
  buildMtlsHeaders: gitdbMocks.mockBuildMtlsHeaders,
  computeCaHash: gitdbMocks.mockComputeCaHash,
}));

// Exposes onboarding hook state and actions so tests can validate setup transitions from user events.
const OnboardingHarness = () => {
  const flow = useOnboardingFlow();
  return (
    <div>
      <div data-testid="mode">{flow.setupMode}</div>
      <div data-testid="error">{flow.setupError ?? ""}</div>
      <div data-testid="discovering">{flow.isDiscovering ? "true" : "false"}</div>
      <div data-testid="password-required">{flow.passwordRequired ? "true" : "false"}</div>
      <button type="button" onClick={() => flow.setServerUrlInput("http://replycant.local:8080")}>
        set-server-url
      </button>
      <button type="button" onClick={() => void flow.handleDiscoverServer()}>
        discover-server
      </button>
      <button type="button" onClick={() => flow.setDeviceNameInput("Test Device")}>
        set-device
      </button>
      <button type="button" onClick={() => flow.setPasswordInput("secret")}>
        set-password
      </button>
      <button type="button" onClick={() => void flow.handleCreateIdentity()}>
        create
      </button>
      <button type="button" onClick={flow.handleStartOver}>
        start-over
      </button>
      <div data-testid="tailnet-available">{flow.tailnetAvailable ? "true" : "false"}</div>
      <div data-testid="pairing-secret">{flow.pairingSecret?.encoded ?? ""}</div>
      <button type="button" onClick={flow.handleBeginTailnetPairing}>
        begin-tailnet
      </button>
    </div>
  );
};

const decodeBase64 = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));

// Provides a valid persisted setup record so onboarding can skip server-url prompt in identity tests.
const saveSetupConfig = () => {
  localStorage.setItem(
    SETUP_CONFIG_STORAGE_KEY,
    JSON.stringify({
      serverUrl: "http://replycant.local:8080",
      ca: "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----",
      url: "https://git.example",
    }),
  );
};

// Installs a desktop bridge stub so Electron-mode onboarding can be exercised in jsdom.
const installDesktopBridge = (options?: {
  available?: boolean;
  keyBase64?: string;
}) => {
  const available = options?.available ?? true;
  const keyBase64 = options?.keyBase64 ?? btoa(String.fromCharCode(...new Uint8Array(32).fill(9)));
  const clearIdentityKey = vi.fn().mockResolvedValue(undefined);
  window.replycantDesktop = {
    platform: "linux",
    minimize: vi.fn(),
    maximize: vi.fn(),
    close: vi.fn(),
    persistedLastPage: null,
    persistLastPage: vi.fn(() => true),
    identityKeyAvailable: vi.fn().mockResolvedValue(available),
    identityKey: vi.fn().mockResolvedValue(keyBase64),
    clearIdentityKey,
  };
  return { clearIdentityKey };
};

// Adds the tailnet half of the desktop bridge, which only the packaged shell
// exposes, so the tailnet path can be driven in jsdom.
const installTailnetBridge = () => {
  if (!window.replycantDesktop) {
    installDesktopBridge();
  }
  const joinTailnet = vi.fn().mockResolvedValue(undefined);
  const leaveTailnet = vi.fn().mockResolvedValue(undefined);
  window.replycantDesktop = { ...window.replycantDesktop!, joinTailnet, leaveTailnet };
  return { joinTailnet, leaveTailnet };
};

describe("useOnboardingFlow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    delete window.replycantDesktop;
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({}),
      }),
    );
    gitdbMocks.mockGetDefaultDeviceName.mockReturnValue("replycant-webapp");
    gitdbMocks.mockBuildMtlsHeaders.mockReturnValue(null);
    gitdbMocks.mockComputeCaHash.mockResolvedValue("ca-hash");
    gitdbMocks.mockSanitizeDeviceName.mockImplementation((value: string) => value.trim());
    pairingMocks.mockCreatePairingSecret.mockResolvedValue({
      encoded: pairingFixture.secret,
      slot: pairingFixture.slot,
    });
    pairingMocks.mockPollForPairingRecord.mockResolvedValue(
      decodeBase64(pairingFixture.sealedBase64),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    delete window.replycantDesktop;
  });

  it("moves into server-url mode when no setup config exists", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    expect(screen.getByTestId("password-required")).toHaveTextContent("true");
  });

  it("moves into create mode after successful setup discovery", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({
            ca: "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----",
            url: "https://git.example",
          }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({}),
        }),
    );
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    fireEvent.click(screen.getByRole("button", { name: "set-server-url" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "discover-server" }));
    });
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
  });

  // Verifies that isDiscovering is true while the server lookup is in flight so
  // the UI can disable controls and show a spinner.
  it("sets isDiscovering while server lookup is in flight", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    let resolveDiscover!: (value: Response) => void;
    vi.stubGlobal(
      "fetch",
      vi.fn().mockReturnValue(
        new Promise<Response>((resolve) => { resolveDiscover = resolve; }),
      ),
    );

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    fireEvent.click(screen.getByRole("button", { name: "set-server-url" }));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "discover-server" }));
    });
    expect(screen.getByTestId("discovering")).toHaveTextContent("true");

    await act(async () => {
      resolveDiscover({
        ok: true,
        json: async () => ({
          ca: "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----",
          url: "https://git.example",
        }),
      } as Response);
    });
    await waitFor(() => expect(screen.getByTestId("discovering")).toHaveTextContent("false"));
  });

  // Ensures onboarding exposes transport failure details so setup errors are actionable for users.
  it("surfaces server discovery detail when fetch fails", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: false,
        json: async () => ({
          error: "Failed to fetch server configuration:",
          detail: "getaddrinfo ENOTFOUND replycant.local",
        }),
      }),
    );

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    fireEvent.click(screen.getByRole("button", { name: "set-server-url" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "discover-server" }));
    });

    await waitFor(() =>
      expect(screen.getByTestId("error")).toHaveTextContent(
        "Failed to fetch server configuration: getaddrinfo ENOTFOUND replycant.local",
      ),
    );
  });

  it("moves into unlock mode when a password-wrapped identity exists", async () => {
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue({
      version: 2,
      wrap: "password",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      deviceName: "test",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
      encryptedPayloadBase64: "AAAA",
      ivBase64: "AAAA",
      saltBase64: "AAAA",
    });

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("unlock"));
    expect(fetch).toHaveBeenCalledWith(
      "/api/setup/configure",
      expect.objectContaining({
        method: "POST",
      }),
    );
  });

  // Electron with safeStorage should unlock device-wrapped identities without a password screen.
  it("auto-unlocks a device-wrapped identity when the OS keyring is available", async () => {
    installDesktopBridge();
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue({
      version: 2,
      wrap: "device",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      deviceName: "desktop",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
      encryptedPayloadBase64: "AAAA",
      ivBase64: "AAAA",
    });
    gitdbMocks.mockUnlockIdentity.mockResolvedValue({
      certificatePem: "cert",
      privateKeyPem: "private",
      agePrivateKeyBase64: "YWJj",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      deviceName: "desktop",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
    });

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));
    expect(screen.getByTestId("password-required")).toHaveTextContent("false");
    expect(gitdbMocks.mockUnlockIdentity).toHaveBeenCalledWith(
      expect.objectContaining({ wrap: "device" }),
      expect.objectContaining({ wrap: "device" }),
    );
  });

  // Browser mode must refuse cleartext creation when the password field is empty.
  it("blocks browser identity creation without a password", async () => {
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    fireEvent.click(screen.getByRole("button", { name: "set-device" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "create" }));
    });
    await waitFor(() =>
      expect(screen.getByTestId("error")).toHaveTextContent(/password is required/i),
    );
    expect(gitdbMocks.mockCreateIdentity).not.toHaveBeenCalled();
  });

  it("creates a password-wrapped identity in browser mode", async () => {
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    gitdbMocks.mockCreateIdentity.mockResolvedValue({
      version: 2,
      wrap: "password",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      encryptedPayloadBase64: "AAAA",
      ivBase64: "AAAA",
      saltBase64: "AAAA",
      deviceName: "Test Device",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
    });
    gitdbMocks.mockUnlockIdentity.mockResolvedValue({
      certificatePem: "cert",
      privateKeyPem: "private",
      agePrivateKeyBase64: "YWJj",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      deviceName: "Test Device",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
    });

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    fireEvent.click(screen.getByRole("button", { name: "set-device" }));
    fireEvent.click(screen.getByRole("button", { name: "set-password" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "create" }));
    });
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("qr"));
    expect(gitdbMocks.mockCreateIdentity).toHaveBeenCalledWith(
      expect.objectContaining({
        keySource: { wrap: "password", password: "secret" },
      }),
    );
    expect(gitdbMocks.mockSaveIdentityRecord).toHaveBeenCalledTimes(1);
  });

  // Electron create path should ignore passwords and use the OS-backed device key.
  it("creates a device-wrapped identity when the OS keyring is available", async () => {
    installDesktopBridge();
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    gitdbMocks.mockCreateIdentity.mockResolvedValue({
      version: 2,
      wrap: "device",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      encryptedPayloadBase64: "AAAA",
      ivBase64: "AAAA",
      deviceName: "Test Device",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
    });
    gitdbMocks.mockUnlockIdentity.mockResolvedValue({
      certificatePem: "cert",
      privateKeyPem: "private",
      agePrivateKeyBase64: "YWJj",
      publicKeySsh: "ssh-ed25519 AAAA test",
      agePublicKey: "age1test",
      deviceName: "Test Device",
      deviceUUID: "uuid-1",
      createdAt: new Date().toISOString(),
    });

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("password-required")).toHaveTextContent("false"));
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    fireEvent.click(screen.getByRole("button", { name: "set-device" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "create" }));
    });
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("qr"));
    expect(gitdbMocks.mockCreateIdentity).toHaveBeenCalledWith(
      expect.objectContaining({
        keySource: expect.objectContaining({ wrap: "device" }),
      }),
    );
  });

  // When safeStorage is only basic_text, Electron must fall back to the password path.
  it("requires a password when the desktop keyring reports unavailable", async () => {
    installDesktopBridge({ available: false });
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("password-required")).toHaveTextContent("true"));
  });

  it("clears persisted setup state and the desktop device key when starting over", async () => {
    const { clearIdentityKey } = installDesktopBridge();
    saveSetupConfig();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({}),
      }),
    );

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));

    fireEvent.click(screen.getByRole("button", { name: "start-over" }));

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    expect(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY)).toBeNull();
    expect(gitdbMocks.mockClearIdentityRecord).toHaveBeenCalledTimes(1);
    expect(clearIdentityKey).toHaveBeenCalledTimes(1);
  });

  // Drives onboarding from the first screen to a waiting pairing QR. The
  // desktop bridge must already be installed, since the tailnet path is only
  // offered there.
  const startTailnetPairing = async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    gitdbMocks.mockCreateIdentity.mockResolvedValue({
      deviceName: "Test Device",
      publicKeySsh: "ssh",
      agePublicKey: pairingFixture.agePublicKeyBase64,
      deviceUUID: "uuid",
      wrap: "device",
    });
    gitdbMocks.mockUnlockIdentity.mockResolvedValue({
      privateKeyPem: "key",
      certificatePem: "cert",
      deviceName: "Test Device",
      agePrivateKeyBase64: pairingFixture.agePrivateKeyBase64,
    });

    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "begin-tailnet" }));
    });
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    fireEvent.click(screen.getByRole("button", { name: "set-device" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "create" }));
    });
  };

  // The tailnet path only exists in the desktop shell, because joining needs a
  // native sidecar the browser build cannot host. Offering it in a browser
  // would lead the user into a dead end.
  it("does not offer the tailnet path without the desktop bridge", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    expect(screen.getByTestId("tailnet-available")).toHaveTextContent("false");
  });

  it("offers the tailnet path in the desktop shell", async () => {
    installTailnetBridge();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("serverUrl"));
    expect(screen.getByTestId("tailnet-available")).toHaveTextContent("true");
  });

  // The secret has to be minted only once there is an age key to seal a record
  // to, since the QR must carry both together for the record to be openable.
  it("mints a pairing secret when identity creation finishes", async () => {
    installTailnetBridge();
    await startTailnetPairing();

    expect(screen.getByTestId("pairing-secret")).toHaveTextContent(pairingFixture.secret);
    expect(pairingMocks.mockCreatePairingSecret).toHaveBeenCalledTimes(1);
  });

  // The whole point of the path: a record sealed by gitd is opened here, the
  // tailnet is joined with the credential inside it, and the proxy is pointed
  // at gitd's MagicDNS name. This exercises the real decryption code against a
  // record the Go writer produced.
  it("joins the tailnet with the credentials from the pairing record", async () => {
    const { joinTailnet } = installTailnetBridge();
    await startTailnetPairing();

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    expect(pairingMocks.mockPollForPairingRecord).toHaveBeenCalledWith(
      expect.objectContaining({ slot: pairingFixture.slot }),
    );
    expect(joinTailnet).toHaveBeenCalledWith(
      expect.objectContaining({
        headscaleAddr: `${pairingFixture.caLabel}.tunnel.replycant.com:443`,
        caPem: pairingFixture.payload.ca_pem,
        preauthKey: pairingFixture.payload.preauth_key,
      }),
    );
  });

  // The proxy has to be told where gitd is before rehydration starts, or the
  // first fetch goes nowhere.
  it("points the proxy at gitd's MagicDNS name", async () => {
    installTailnetBridge();
    await startTailnetPairing();

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    const stored = JSON.parse(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY) ?? "{}") as {
      url?: string;
      ca?: string;
    };
    expect(stored.url).toBe("https://gitd.replycant.internal");
    expect(stored.ca).toBe(pairingFixture.payload.ca_pem);
  });

  // A cold start has to rejoin, because the node only exists while the sidecar
  // runs. It must use no pre-auth key: that credential was single-use.
  it("rejoins the tailnet on a later start without a pre-auth key", async () => {
    const { joinTailnet } = installTailnetBridge();
    saveSetupConfig();
    localStorage.setItem(
      TAILNET_CONFIG_STORAGE_KEY,
      JSON.stringify({
        headscaleAddr: "abc.tunnel.replycant.com:443",
        headscaleServerName: "abc.tunnel.replycant.com",
        gitdTailnetName: "gitd",
        baseDomain: "replycant.internal",
      }),
    );
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue({ wrap: "device", publicKeySsh: "ssh" });
    gitdbMocks.mockUnlockIdentity.mockResolvedValue({
      privateKeyPem: "key",
      certificatePem: "cert",
      deviceName: "Test Device",
      agePrivateKeyBase64: pairingFixture.agePrivateKeyBase64,
    });

    render(<OnboardingHarness />);

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));
    expect(joinTailnet).toHaveBeenCalledTimes(1);
    expect(joinTailnet.mock.calls[0][0]).not.toHaveProperty("preauthKey");
  });

  // Nothing is persisted before the tailnet is actually up, so a failure leaves
  // the next start with no configuration it would wrongly trust.
  it("persists nothing when joining the tailnet fails", async () => {
    const { joinTailnet } = installTailnetBridge();
    joinTailnet.mockRejectedValue(new Error("sidecar failed to start"));

    await startTailnetPairing();

    await waitFor(() =>
      expect(screen.getByTestId("error")).toHaveTextContent("sidecar failed to start"),
    );
    expect(screen.getByTestId("mode")).toHaveTextContent("tailnetPairing");
    expect(localStorage.getItem(TAILNET_CONFIG_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY)).toBeNull();
  });

  // A record that opens but names a CA the headscale hostname does not commit
  // to must not be installed as a trust root, even though it decrypted cleanly.
  it("refuses a pairing record whose CA does not match its hostname", async () => {
    const { joinTailnet } = installTailnetBridge();
    pairingMocks.mockPollForPairingRecord.mockResolvedValue(
      decodeBase64(pairingFixture.mismatchedCaSealedBase64),
    );

    await startTailnetPairing();

    await waitFor(() =>
      expect(screen.getByTestId("error")).toHaveTextContent(/does not match the fingerprint/),
    );
    expect(joinTailnet).not.toHaveBeenCalled();
  });

  // A record planted by someone who guessed the slot cannot open, and the
  // failure has to name the cause rather than looking like a stalled pairing.
  it("reports a record that does not open under this attempt's secret", async () => {
    const { joinTailnet } = installTailnetBridge();
    pairingMocks.mockPollForPairingRecord.mockResolvedValue(
      decodeBase64(pairingFixture.otherSecretSealedBase64),
    );

    await startTailnetPairing();

    await waitFor(() =>
      expect(screen.getByTestId("error")).toHaveTextContent(/did not open under this pairing secret/),
    );
    expect(joinTailnet).not.toHaveBeenCalled();
  });

  // Starting over discards the identity the tailnet node was authorized
  // against, so the node must not keep running with it.
  it("leaves the tailnet when the user starts over", async () => {
    const { leaveTailnet } = installTailnetBridge();
    await startTailnetPairing();
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "start-over" }));
    });

    expect(leaveTailnet).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem(TAILNET_CONFIG_STORAGE_KEY)).toBeNull();
  });
});
