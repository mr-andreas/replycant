import { useCallback, useEffect, useMemo, useState } from "react";
import { SETUP_CONFIG_STORAGE_KEY } from "../../lib/config";
import { ensureProxySession } from "../../lib/proxySession";
import {
  buildMtlsHeaders,
  clearIdentityRecord,
  computeCaHash,
  createIdentity,
  DecryptedIdentity,
  getDefaultDeviceName,
  IdentityKeySource,
  loadIdentityRecord,
  sanitizeDeviceName,
  saveIdentityRecord,
  unlockIdentity,
} from "../gitdb";

// Defines setup phases so onboarding can keep identity creation and unlock behavior deterministic.
export type SetupMode = "checking" | "serverUrl" | "create" | "unlock" | "qr" | "rehydrating" | "ready";

// Captures browser-owned setup fields that must survive proxy restarts and page reloads.
interface SetupConfigRecord {
  serverUrl: string;
  ca: string;
  url: string;
}

// Loads persisted setup config so onboarding can rehydrate proxy state before identity steps.
const loadSetupConfigRecord = (): SetupConfigRecord | null => {
  const raw = localStorage.getItem(SETUP_CONFIG_STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SetupConfigRecord>;
    if (
      typeof parsed.serverUrl !== "string" ||
      typeof parsed.ca !== "string" ||
      typeof parsed.url !== "string"
    ) {
      return null;
    }
    return {
      serverUrl: parsed.serverUrl,
      ca: parsed.ca,
      url: parsed.url,
    };
  } catch {
    return null;
  }
};

// Persists setup config locally so browser remains the sole durable source of setup truth.
const saveSetupConfigRecord = (record: SetupConfigRecord): void => {
  localStorage.setItem(SETUP_CONFIG_STORAGE_KEY, JSON.stringify(record));
};

// Clears stored setup config when discovery/configuration fails irrecoverably.
const clearSetupConfigRecord = (): void => {
  localStorage.removeItem(SETUP_CONFIG_STORAGE_KEY);
};

// Decodes the Electron IPC device key so WebCrypto can import it as AES-GCM material.
const decodeDeviceKey = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));

// Asks the desktop shell whether OS-keyring device wrap is available for silent unlock.
const probeDeviceKeyAvailable = async (): Promise<boolean> => {
  const desktop = window.replycantDesktop;
  if (!desktop?.identityKeyAvailable) return false;
  try {
    return await desktop.identityKeyAvailable();
  } catch {
    return false;
  }
};

// Loads the OS-wrapped device key from the main process for encrypt/unlock.
const loadDesktopDeviceKey = async (): Promise<Uint8Array | null> => {
  const desktop = window.replycantDesktop;
  if (!desktop?.identityKey) return null;
  try {
    return decodeDeviceKey(await desktop.identityKey());
  } catch {
    return null;
  }
};

// Captures onboarding state and actions so App can compose setup screens without owning setup logic.
export interface OnboardingFlowState {
  setupMode: SetupMode;
  setupError: string | null;
  rehydrationKey: number;
  passwordInput: string;
  deviceNameInput: string;
  serverUrlInput: string;
  passwordRequired: boolean;
  identityRecord: ReturnType<typeof loadIdentityRecord>;
  identity: DecryptedIdentity | null;
  mtlsHeaders: Record<string, string> | null;
  setupConfig: SetupConfigRecord | null;
  caHash: string | null;
  isDiscovering: boolean;
  setSetupMode: (mode: SetupMode) => void;
  setSetupError: (message: string | null) => void;
  setPasswordInput: (value: string) => void;
  setDeviceNameInput: (value: string) => void;
  setServerUrlInput: (value: string) => void;
  handleDiscoverServer: () => Promise<void>;
  handleCreateIdentity: () => Promise<void>;
  handleUnlockIdentity: () => Promise<void>;
  handleStartOver: () => void;
  retryRehydration: () => void;
}

// Owns first-run identity bootstrap so additional library views can share one setup flow.
export const useOnboardingFlow = (): OnboardingFlowState => {
  const [setupMode, setSetupMode] = useState<SetupMode>("checking");
  const [setupError, setSetupError] = useState<string | null>(null);
  const [rehydrationKey, setRehydrationKey] = useState(0);
  const [passwordInput, setPasswordInput] = useState("");
  const [deviceNameInput, setDeviceNameInput] = useState(() => getDefaultDeviceName());
  const [serverUrlInput, setServerUrlInput] = useState("");
  const [passwordRequired, setPasswordRequired] = useState(true);
  const [identityRecord, setIdentityRecord] = useState<ReturnType<typeof loadIdentityRecord>>(null);
  const [identity, setIdentity] = useState<DecryptedIdentity | null>(null);
  const [setupConfig, setSetupConfig] = useState<SetupConfigRecord | null>(null);
  const [caHash, setCaHash] = useState<string | null>(null);
  const [isDiscovering, setIsDiscovering] = useState(false);
  const mtlsHeaders = useMemo(() => (identity ? buildMtlsHeaders(identity) : null), [identity]);

  // Restores identity state once proxy setup is configured so users always land in the correct onboarding step.
  const resolveIdentitySetup = useCallback(async () => {
    const stored = loadIdentityRecord();
    if (!stored) {
      setSetupMode("create");
      return;
    }
    setIdentityRecord(stored);
    if (stored.wrap === "password") {
      setSetupMode("unlock");
      return;
    }
    try {
      const deviceKey = await loadDesktopDeviceKey();
      const unlocked = await unlockIdentity(stored, { wrap: "device", deviceKey });
      setIdentity(unlocked);
      setSetupMode("rehydrating");
    } catch (error) {
      setSetupError(
        error instanceof Error
          ? error.message
          : "Failed to unlock local identity with the OS keyring.",
      );
      setSetupMode("create");
    }
  }, []);

  // Pushes browser-owned setup config into proxy memory so git/lfs routes are usable after restarts.
  const configureProxy = useCallback(async (config: SetupConfigRecord): Promise<void> => {
    const response = await fetch("/api/setup/configure", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        ca: config.ca,
        url: config.url,
      }),
    });
    if (!response.ok) {
      let detail = "";
      try {
        const payload = (await response.json()) as { error?: string };
        detail = payload.error ? ` ${payload.error}` : "";
      } catch {
        // Keeps proxy setup errors readable even when response body is not JSON.
      }
      throw new Error(`Failed to configure proxy.${detail}`);
    }
  }, []);

  // Rehydrates setup config on startup so onboarding resumes without requiring repeated server URL entry.
  useEffect(() => {
    void (async () => {
      const deviceKeyAvailable = await probeDeviceKeyAvailable();
      setPasswordRequired(!deviceKeyAvailable);
      const storedConfig = loadSetupConfigRecord();
      if (!storedConfig) {
        setSetupMode("serverUrl");
        return;
      }
      setSetupConfig(storedConfig);
      setServerUrlInput(storedConfig.serverUrl);
      try {
        await configureProxy(storedConfig);
      } catch (error) {
        clearSetupConfigRecord();
        setSetupConfig(null);
        setSetupError(error instanceof Error ? error.message : "Failed to configure server setup.");
        setSetupMode("serverUrl");
        return;
      }
      await resolveIdentitySetup();
    })();
  }, [configureProxy, resolveIdentitySetup]);

  // Hands the unlocked identity to the proxy so direct-play video requests,
  // which cannot carry mTLS headers on a media element, still authenticate.
  useEffect(() => {
    void ensureProxySession(mtlsHeaders).catch((error: unknown) => {
      console.warn("[replycant-setup] failed to register proxy session", error);
    });
  }, [mtlsHeaders]);

  // Computes deterministic CA hash once setup config is available so QR payload can be iOS-verifiable.
  useEffect(() => {
    if (!setupConfig?.ca) {
      setCaHash(null);
      return;
    }
    void (async () => {
      try {
        setCaHash(await computeCaHash(setupConfig.ca));
      } catch (error) {
        setCaHash(null);
        setSetupError(error instanceof Error ? error.message : "Failed to compute CA hash.");
      }
    })();
  }, [setupConfig?.ca]);

  // Discovers setup config from caserver URL and persists it before identity creation starts.
  const handleDiscoverServer = useCallback(async () => {
    try {
      setSetupError(null);
      const serverUrl = serverUrlInput.trim();
      if (!serverUrl) {
        setSetupError("Server URL is required.");
        return;
      }
      try {
        // Uses URL parsing to fail fast on malformed inputs before network discovery.
        // eslint-disable-next-line no-new
        new URL(serverUrl);
      } catch {
        setSetupError("Server URL must be a valid URL.");
        return;
      }
      setIsDiscovering(true);
      const response = await fetch("/api/setup/discover", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ serverUrl }),
      });
      if (!response.ok) {
        const payload = (await response.json().catch(() => ({}))) as {
          error?: string;
          detail?: string;
        };
        const message = payload.error ?? "Failed to discover server configuration.";
        const detail = payload.detail ? ` ${payload.detail}` : "";
        throw new Error(`${message}${detail}`);
      }
      const discovered = (await response.json()) as Partial<SetupConfigRecord>;
      if (
        typeof discovered.ca !== "string" ||
        typeof discovered.url !== "string"
      ) {
        throw new Error("Server configuration payload is invalid.");
      }
      const record: SetupConfigRecord = {
        serverUrl,
        ca: discovered.ca,
        url: discovered.url,
      };
      await configureProxy(record);
      saveSetupConfigRecord(record);
      setSetupConfig(record);
      setSetupMode("create");
    } catch (error) {
      setSetupError(error instanceof Error ? error.message : "Failed to discover server configuration.");
    } finally {
      setIsDiscovering(false);
    }
  }, [configureProxy, serverUrlInput]);

  // Creates browser-held credentials always encrypted at rest before persistence.
  const handleCreateIdentity = useCallback(async () => {
    try {
      setSetupError(null);
      const deviceName = sanitizeDeviceName(deviceNameInput);
      if (!deviceName) {
        setSetupError("Device name is required.");
        return;
      }
      let keySource: IdentityKeySource;
      if (passwordRequired) {
        const password = passwordInput.trim();
        if (!password) {
          setSetupError("Password is required to protect identity secrets.");
          return;
        }
        keySource = { wrap: "password", password };
      } else {
        const deviceKey = await loadDesktopDeviceKey();
        if (!deviceKey) {
          setSetupError("OS keyring is unavailable. Restart the desktop app or set a browser password flow.");
          return;
        }
        keySource = { wrap: "device", deviceKey };
      }
      const created = await createIdentity({ keySource, deviceName });
      saveIdentityRecord(created);
      setIdentityRecord(created);
      const unlocked = await unlockIdentity(created, keySource);
      setIdentity(unlocked);
      setSetupMode("qr");
      setPasswordInput("");
      setDeviceNameInput(created.deviceName);
    } catch (error) {
      setSetupError(error instanceof Error ? error.message : "Failed to create identity.");
    }
  }, [deviceNameInput, passwordInput, passwordRequired]);

  // Decrypts password-wrapped credentials so setup can continue without recreating identity.
  const handleUnlockIdentity = useCallback(async () => {
    if (!identityRecord) return;
    try {
      setSetupError(null);
      if (identityRecord.wrap !== "password") {
        throw new Error("This identity does not use password unlock.");
      }
      const unlocked = await unlockIdentity(identityRecord, {
        wrap: "password",
        password: passwordInput,
      });
      setIdentity(unlocked);
      setSetupMode("rehydrating");
      setPasswordInput("");
    } catch (error) {
      setSetupError(error instanceof Error ? error.message : "Incorrect password.");
    }
  }, [identityRecord, passwordInput]);

  // Provides an explicit escape hatch when users need to restart setup against a different server.
  const handleStartOver = useCallback(() => {
    clearSetupConfigRecord();
    clearIdentityRecord();
    void window.replycantDesktop?.clearIdentityKey?.().catch(() => {
      // Clearing is best-effort; local identity record removal is the durable reset.
    });
    setSetupMode("serverUrl");
    setSetupError(null);
    setSetupConfig(null);
    setCaHash(null);
    setIdentityRecord(null);
    setIdentity(null);
    setPasswordInput("");
    setServerUrlInput("");
  }, []);

  // Lets users retry failed rehydration explicitly so bootstrap failures are recoverable.
  const retryRehydration = useCallback(() => {
    setSetupError(null);
    setRehydrationKey((current) => current + 1);
  }, []);

  return {
    setupMode,
    setupError,
    rehydrationKey,
    passwordInput,
    deviceNameInput,
    serverUrlInput,
    passwordRequired,
    identityRecord,
    identity,
    mtlsHeaders,
    setupConfig,
    caHash,
    isDiscovering,
    setSetupMode,
    setSetupError,
    setPasswordInput,
    setDeviceNameInput,
    setServerUrlInput,
    handleDiscoverServer,
    handleCreateIdentity,
    handleUnlockIdentity,
    handleStartOver,
    retryRehydration,
  };
};
