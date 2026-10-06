import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { SyncSnapshot } from "../gitdb";
import { OnboardingGate } from "./OnboardingGate";
import type { OnboardingFlowState } from "./useOnboardingFlow";

const snapshot: SyncSnapshot = {
  syncing: false,
  error: null,
  unrecoverableError: null,
  syncedCommitHash: null,
  lastSyncAt: null,
  periodicSyncPaused: false,
  periodicSyncUserEnabled: true,
  syncIntervalMs: 2000,
  isOffHead: false,
  requiresHardResetPermission: false,
  cloneProgress: null,
};

describe("OnboardingGate", () => {
  // Builds a complete flow object so mode-specific tests can override only relevant values.
  const buildFlow = (overrides: Partial<OnboardingFlowState>): OnboardingFlowState => ({
    setupMode: "create",
    setupError: null,
    rehydrationKey: 0,
    passwordInput: "",
    deviceNameInput: "",
    passwordRequired: true,
    identityRecord: null,
    identity: null,
    mtlsHeaders: null,
    pairingSecret: null,
    setSetupMode: vi.fn(),
    setSetupError: vi.fn(),
    setPasswordInput: vi.fn(),
    setDeviceNameInput: vi.fn(),
    handleCreateIdentity: vi.fn().mockResolvedValue(undefined),
    handleUnlockIdentity: vi.fn().mockResolvedValue(undefined),
    handleStartOver: vi.fn(),
    retryRehydration: vi.fn(),
    ...overrides,
  });

  // The browser build cannot join a tailnet, so it must say what to use
  // instead rather than show a setup flow that can never finish.
  it("tells browser users the desktop app is required", () => {
    const flow = buildFlow({ setupMode: "desktopRequired" });
    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("heading", { name: "Desktop app required" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Start over" })).not.toBeInTheDocument();
  });

  // Scripted approval (the desktop integration suite) reads the same payload
  // the QR encodes, so it must be exactly what a scanning phone would see.
  it("exposes the pairing QR payload on the QR container", () => {
    const flow = buildFlow({
      setupMode: "tailnetPairing",
      identityRecord: {
        version: 2,
        wrap: "device",
        publicKeySsh: "ssh-ed25519 AAAA test",
        agePublicKey: "age1test",
        deviceName: "desk",
        deviceUUID: "uuid-1",
        createdAt: "2026-01-01T00:00:00.000Z",
        encryptedPayloadBase64: "AAAA",
        ivBase64: "AAAA",
      },
      pairingSecret: { encoded: "secret-1", slot: "slot-1" } as OnboardingFlowState["pairingSecret"],
    });
    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    const payload = JSON.parse(screen.getByTestId("pairing-qr").getAttribute("data-payload") ?? "{}");
    expect(payload).toEqual({
      pubkey: "ssh-ed25519 AAAA test",
      age_pubkey: "age1test",
      name: "desk",
      uuid: "uuid-1",
      pairing_secret: "secret-1",
    });
  });

  it("submits create identity step when Enter is pressed", async () => {
    const user = userEvent.setup();
    const handleCreateIdentity = vi.fn().mockResolvedValue(undefined);
    const flow = buildFlow({
      setupMode: "create",
      deviceNameInput: "replycant-webapp",
      handleCreateIdentity,
    });

    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    await user.click(screen.getByPlaceholderText("replycant-webapp"));
    await user.keyboard("{Enter}");
    expect(handleCreateIdentity).toHaveBeenCalledTimes(1);
  });

  // Without an OS keyring the identity is password-wrapped, so a password is collected.
  it("shows the password field when passwordRequired is true", () => {
    const flow = buildFlow({ setupMode: "create", passwordRequired: true });
    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByLabelText("Password")).toBeVisible();
  });

  // Electron with a strong safeStorage backend skips password UI for silent unlock.
  it("hides the password field when passwordRequired is false", () => {
    const flow = buildFlow({ setupMode: "create", passwordRequired: false });
    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
  });

  it("submits unlock step when Enter is pressed", async () => {
    const user = userEvent.setup();
    const handleUnlockIdentity = vi.fn().mockResolvedValue(undefined);
    const flow = buildFlow({
      setupMode: "unlock",
      handleUnlockIdentity,
    });

    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    await user.click(screen.getByLabelText("Password"));
    await user.keyboard("{Enter}");
    expect(handleUnlockIdentity).toHaveBeenCalledTimes(1);
  });

  it("shows start over action on every setup step", () => {
    const createFlow = buildFlow({ setupMode: "create" });
    const unlockFlow = buildFlow({ setupMode: "unlock" });
    const pairingFlow = buildFlow({ setupMode: "tailnetPairing" });
    const rehydratingFlow = buildFlow({ setupMode: "rehydrating" });

    const { rerender } = render(<OnboardingGate flow={createFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={unlockFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={pairingFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={rehydratingFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();
  });

  it("calls handleStartOver when start over action is clicked", async () => {
    const user = userEvent.setup();
    const handleStartOver = vi.fn();
    const flow = buildFlow({
      setupMode: "create",
      handleStartOver,
    });

    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    await user.click(screen.getByRole("button", { name: "Start over" }));
    expect(handleStartOver).toHaveBeenCalledTimes(1);
  });
});
