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
}));

// Exposes onboarding hook state and actions so tests can validate setup transitions from user events.
const OnboardingHarness = () => {
  const flow = useOnboardingFlow();
  return (
    <div>
      <div data-testid="mode">{flow.setupMode}</div>
      <div data-testid="error">{flow.setupError ?? ""}</div>
      <div data-testid="password-required">{flow.passwordRequired ? "true" : "false"}</div>
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
      <div data-testid="pairing-secret">{flow.pairingSecret?.encoded ?? ""}</div>
    </div>
  );
};

const decodeBase64 = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));

// Provides the setup record a completed pairing leaves behind, so identity
// tests can start from a device that has already paired.
const saveSetupConfig = () => {
  localStorage.setItem(
    SETUP_CONFIG_STORAGE_KEY,
    JSON.stringify({
      ca: "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----",
      url: "https://gitd.replycant.internal:8443",
    }),
  );
};

// Installs the desktop bridge, including the tailnet half, so the onboarding
// the app actually ships can be exercised in jsdom.
const installDesktopBridge = (options?: {
  available?: boolean;
  keyBase64?: string;
}) => {
  const available = options?.available ?? true;
  const keyBase64 = options?.keyBase64 ?? btoa(String.fromCharCode(...new Uint8Array(32).fill(9)));
  const clearIdentityKey = vi.fn().mockResolvedValue(undefined);
  const joinTailnet = vi.fn().mockResolvedValue(undefined);
  const leaveTailnet = vi.fn().mockResolvedValue(undefined);
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
    joinTailnet,
    leaveTailnet,
  };
  return { clearIdentityKey, joinTailnet, leaveTailnet };
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

  // Joining a tailnet needs the native sidecar, so a plain browser has no
  // way to reach a library at all. Saying so up front beats a setup flow
  // that cannot finish.
  it("shows the desktop-required screen without the desktop bridge", async () => {
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("desktopRequired"));
    expect(fetch).not.toHaveBeenCalled();
  });

  // There is no server to enter: the device creates its keys, shows the
  // pairing QR, and learns everything else from the sealed record.
  it("starts at identity creation in the desktop shell", async () => {
    installDesktopBridge();
    gitdbMocks.mockLoadIdentityRecord.mockReturnValue(null);
    render(<OnboardingHarness />);
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
  });

  it("moves into unlock mode when a password-wrapped identity exists", async () => {
    installDesktopBridge({ available: false });
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

  // Without an OS keyring the identity is password-wrapped, and creation must
  // refuse rather than store the keys in cleartext.
  it("blocks identity creation without a password when the keyring is unavailable", async () => {
    installDesktopBridge({ available: false });
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

  it("creates a password-wrapped identity when the keyring is unavailable", async () => {
    installDesktopBridge({ available: false });
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
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("tailnetPairing"));
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
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("tailnetPairing"));
    expect(gitdbMocks.mockCreateIdentity).toHaveBeenCalledWith(
      expect.objectContaining({
        keySource: expect.objectContaining({ wrap: "device" }),
      }),
    );
  });

  // When safeStorage is only basic_text, Electron must fall back to the password path.
  it("requires a password when the desktop keyring reports unavailable", async () => {
    installDesktopBridge({ available: false });
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

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    expect(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY)).toBeNull();
    expect(gitdbMocks.mockClearIdentityRecord).toHaveBeenCalledTimes(1);
    expect(clearIdentityKey).toHaveBeenCalledTimes(1);
  });

  // Drives onboarding from the first screen to a waiting pairing QR.
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
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("create"));
    fireEvent.click(screen.getByRole("button", { name: "set-device" }));
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "create" }));
    });
  };

  // The secret has to be minted only once there is an age key to seal a record
  // to, since the QR must carry both together for the record to be openable.
  it("mints a pairing secret when identity creation finishes", async () => {
    installDesktopBridge();
    await startTailnetPairing();

    expect(screen.getByTestId("pairing-secret")).toHaveTextContent(pairingFixture.secret);
    expect(pairingMocks.mockCreatePairingSecret).toHaveBeenCalledTimes(1);
  });

  // The desktop integration suite redirects polling to a fake discovery host
  // through the shell; without an override the hosted service is used.
  it("polls the discovery origin the desktop shell names", async () => {
    installDesktopBridge();
    window.replycantDesktop!.discoveryBaseUrl = vi.fn().mockResolvedValue("http://discovery.test:18082");
    await startTailnetPairing();

    await waitFor(() =>
      expect(pairingMocks.mockPollForPairingRecord).toHaveBeenCalledWith(
        expect.objectContaining({ discoveryBase: "http://discovery.test:18082" }),
      ),
    );
  });

  // The whole point of the path: a record sealed by gitd is opened here, the
  // tailnet is joined at the control plane it names, and the proxy is pointed
  // at gitd's MagicDNS name. This exercises the real decryption code against a
  // record the Go writer produced. No key is passed: this device's key is
  // already in pubkeys/, so the sidecar mints one from hsproxy itself.
  it("joins the tailnet at the control plane from the pairing record", async () => {
    const { joinTailnet } = installDesktopBridge();
    await startTailnetPairing();

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    expect(pairingMocks.mockPollForPairingRecord).toHaveBeenCalledWith(
      expect.objectContaining({ slot: pairingFixture.slot }),
    );
    expect(joinTailnet).toHaveBeenCalledWith(
      expect.objectContaining({
        headscaleAddr: `${pairingFixture.caLabel}.tunnel.replycant.com:443`,
        caPem: pairingFixture.payload.ca_pem,
      }),
    );
    expect(joinTailnet.mock.calls[0][0]).not.toHaveProperty("preauthKey");
  });

  // The proxy has to be told where gitd is before rehydration starts, or the
  // first fetch goes nowhere.
  it("points the proxy at gitd's MagicDNS name", async () => {
    installDesktopBridge();
    await startTailnetPairing();

    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    const stored = JSON.parse(localStorage.getItem(SETUP_CONFIG_STORAGE_KEY) ?? "{}") as {
      url?: string;
      ca?: string;
    };
    expect(stored.url).toBe("https://gitd.replycant.internal:8443");
    expect(stored.ca).toBe(pairingFixture.payload.ca_pem);
  });

  // A cold start has to rejoin, because the node only exists while the sidecar
  // runs. It passes no key; the sidecar mints one if headscale forgot it.
  it("rejoins the tailnet on a later start without a pre-auth key", async () => {
    const { joinTailnet } = installDesktopBridge();
    saveSetupConfig();
    localStorage.setItem(
      TAILNET_CONFIG_STORAGE_KEY,
      JSON.stringify({
        headscaleAddr: "abc.tunnel.replycant.com:443",
        headscaleServerName: "abc.tunnel.replycant.com",
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
    const { joinTailnet } = installDesktopBridge();
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
    const { joinTailnet } = installDesktopBridge();
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
    const { joinTailnet } = installDesktopBridge();
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
    const { leaveTailnet } = installDesktopBridge();
    await startTailnetPairing();
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("rehydrating"));

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "start-over" }));
    });

    expect(leaveTailnet).toHaveBeenCalledTimes(1);
    expect(localStorage.getItem(TAILNET_CONFIG_STORAGE_KEY)).toBeNull();
  });
});
