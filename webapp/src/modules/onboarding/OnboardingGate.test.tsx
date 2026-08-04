import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { SyncSnapshot } from "../gitdb";
import { OnboardingGate } from "./OnboardingGate";
import type { OnboardingFlowState } from "./useOnboardingFlow";

const snapshot: SyncSnapshot = {
  syncing: false,
  error: null,
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
    setupMode: "serverUrl",
    setupError: null,
    rehydrationKey: 0,
    passwordInput: "",
    deviceNameInput: "",
    serverUrlInput: "",
    passwordRequired: true,
    identityRecord: null,
    identity: null,
    mtlsHeaders: null,
    setupConfig: null,
    caHash: null,
    isDiscovering: false,
    setSetupMode: vi.fn(),
    setSetupError: vi.fn(),
    setPasswordInput: vi.fn(),
    setDeviceNameInput: vi.fn(),
    setServerUrlInput: vi.fn(),
    handleDiscoverServer: vi.fn().mockResolvedValue(undefined),
    handleCreateIdentity: vi.fn().mockResolvedValue(undefined),
    handleUnlockIdentity: vi.fn().mockResolvedValue(undefined),
    handleStartOver: vi.fn(),
    retryRehydration: vi.fn(),
    ...overrides,
  });

  it("submits server URL step when Enter is pressed", async () => {
    const user = userEvent.setup();
    const handleDiscoverServer = vi.fn().mockResolvedValue(undefined);
    const flow = buildFlow({
      setupMode: "serverUrl",
      serverUrlInput: "http://localhost:18080",
      handleDiscoverServer,
    });

    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    await user.click(screen.getByPlaceholderText("http://replycant.local:8080"));
    await user.keyboard("{Enter}");
    expect(handleDiscoverServer).toHaveBeenCalledTimes(1);
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

  // Browser mode must collect a password because there is no OS keyring wrap.
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

  // Verifies the serverUrl form disables input and hides button text while
  // discovery is in progress so users get visual feedback.
  it("disables input and shows spinner on Continue button while discovering", () => {
    const flow = buildFlow({
      setupMode: "serverUrl",
      serverUrlInput: "http://replycant.local:8080",
      isDiscovering: true,
    });

    render(<OnboardingGate flow={flow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    const input = screen.getByPlaceholderText("http://replycant.local:8080") as HTMLInputElement;
    expect(input.disabled).toBe(true);
    const button = screen.getByRole("button", { name: "" });
    expect(button).toBeDisabled();
    expect(button.querySelector(".button-spinner")).toBeTruthy();
  });

  it("shows start over action on setup steps after server discovery", () => {
    const createFlow = buildFlow({ setupMode: "create" });
    const unlockFlow = buildFlow({ setupMode: "unlock" });
    const qrFlow = buildFlow({ setupMode: "qr" });
    const rehydratingFlow = buildFlow({ setupMode: "rehydrating" });
    const serverUrlFlow = buildFlow({ setupMode: "serverUrl" });

    const { rerender } = render(<OnboardingGate flow={createFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={unlockFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={qrFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={rehydratingFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.getByRole("button", { name: "Start over" })).toBeVisible();

    rerender(<OnboardingGate flow={serverUrlFlow} snapshot={snapshot}><div>app</div></OnboardingGate>);
    expect(screen.queryByRole("button", { name: "Start over" })).not.toBeInTheDocument();
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
