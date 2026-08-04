import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOnboardingFlow } from "./useOnboardingFlow";
import { SETUP_CONFIG_STORAGE_KEY } from "../../lib/config";

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
    </div>
  );
};

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
});
