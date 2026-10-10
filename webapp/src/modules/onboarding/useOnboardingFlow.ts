import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SETUP_CONFIG_STORAGE_KEY } from "../../lib/config";
import { pollForPairingRecord } from "../../lib/discovery";
import { createPairingSecret, openPairingRecord, PairingSecret } from "../../lib/pairing";
import { ensureProxySession } from "../../lib/proxySession";
import {
  clearTailnetConfigRecord,
  gitdTailnetUrl,
  joinTailnet,
  loadTailnetConfigRecord,
  saveTailnetConfigRecord,
  tailnetSupported,
  toTailnetConfigRecord,
} from "../../lib/tailnet";
import {
  buildMtlsHeaders,
  clearIdentityRecord,
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
//
// desktopRequired is terminal: gitd is only reachable over the tailnet, and
// joining one needs the desktop app's native sidecar.
export type SetupMode =
  | "checking"
  | "desktopRequired"
  | "create"
  | "unlock"
  | "tailnetPairing"
  | "rehydrating"
  | "ready";

// Captures the trust root and gitd origin a completed pairing produced, so
// the proxy can be reconfigured after restarts without pairing again.
interface SetupConfigRecord {
  ca: string;
  url: string;
}

// Loads persisted setup config so onboarding can rehydrate proxy state before identity steps.
const loadSetupConfigRecord = (): SetupConfigRecord | null => {
  const raw = localStorage.getItem(SETUP_CONFIG_STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SetupConfigRecord>;
    if (typeof parsed.ca !== "string" || typeof parsed.url !== "string") {
      return null;
    }
    return { ca: parsed.ca, url: parsed.url };
  } catch {
    return null;
  }
};

// Persists setup config locally so browser remains the sole durable source of setup truth.
const saveSetupConfigRecord = (record: SetupConfigRecord): void => {
  localStorage.setItem(SETUP_CONFIG_STORAGE_KEY, JSON.stringify(record));
};

// Clears stored setup config when the proxy refuses it or the user starts over.
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
  passwordRequired: boolean;
  identityRecord: ReturnType<typeof loadIdentityRecord>;
  identity: DecryptedIdentity | null;
  mtlsHeaders: Record<string, string> | null;

  // The pairing secret for the attempt in progress. Present only while the
  // pairing QR is on screen, because a secret must never outlive its attempt.
  pairingSecret: PairingSecret | null;

  setSetupMode: (mode: SetupMode) => void;
  setSetupError: (message: string | null) => void;
  setPasswordInput: (value: string) => void;
  setDeviceNameInput: (value: string) => void;
  handleCreateIdentity: () => Promise<void>;
  handleUnlockIdentity: () => Promise<void>;
  handleStartOver: () => void;
  retryRehydration: () => void;
}

// Owns first-run identity bootstrap so additional library views can share one setup flow.
//
// A new device has no server to talk to until it is paired: it creates its
// keys, shows a QR with its public key and a pairing secret, and waits for an
// already-paired device to approve it. Everything else arrives in the sealed
// pairing record.
export const useOnboardingFlow = (): OnboardingFlowState => {
  const [setupMode, setSetupMode] = useState<SetupMode>("checking");
  const [setupError, setSetupError] = useState<string | null>(null);
  const [rehydrationKey, setRehydrationKey] = useState(0);
  const [passwordInput, setPasswordInput] = useState("");
  const [deviceNameInput, setDeviceNameInput] = useState(() => getDefaultDeviceName());
  const [passwordRequired, setPasswordRequired] = useState(true);
  const [identityRecord, setIdentityRecord] = useState<ReturnType<typeof loadIdentityRecord>>(null);
  const [identity, setIdentity] = useState<DecryptedIdentity | null>(null);
  const [pairingSecret, setPairingSecret] = useState<PairingSecret | null>(null);

  // Abandons an in-flight discovery poll when the user starts over or the
  // component unmounts, so a discarded attempt stops consuming slot reads.
  const pairingAbort = useRef<AbortController | null>(null);
  const mtlsHeaders = useMemo(() => (identity ? buildMtlsHeaders(identity) : null), [identity]);

  // Rejoins the tailnet before any request is allowed to depend on it.
  //
  // The tailnet node only exists while the desktop sidecar runs, so every cold
  // start has to rejoin. No credential is needed: the node's key material
  // persists in the sidecar's state directory, and the device presents the same
  // identity certificate it uses for gitd.
  //
  // Called on the way into rehydration rather than from an effect, because the
  // first git fetch would otherwise race the tailnet coming up and fail in a
  // way that looks like the server being down.
  const ensureTailnetJoined = useCallback(
    async (unlocked: DecryptedIdentity, ca: string | undefined): Promise<void> => {
      const record = loadTailnetConfigRecord();
      if (!record || !ca) {
        return;
      }
      await joinTailnet({ record, caPem: ca, identity: unlocked });
    },
    [],
  );

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
      await ensureTailnetJoined(unlocked, loadSetupConfigRecord()?.ca);
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
  }, [ensureTailnetJoined]);

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

  // Restores a paired device on startup, or starts a new one at identity
  // creation. A device that never finished pairing has no setup config, and
  // its pairing secret did not survive the restart, so it starts over.
  useEffect(() => {
    void (async () => {
      if (!tailnetSupported()) {
        setSetupMode("desktopRequired");
        return;
      }
      const deviceKeyAvailable = await probeDeviceKeyAvailable();
      setPasswordRequired(!deviceKeyAvailable);
      const storedConfig = loadSetupConfigRecord();
      if (!storedConfig) {
        setSetupMode("create");
        return;
      }
      try {
        await configureProxy(storedConfig);
      } catch (error) {
        clearSetupConfigRecord();
        setSetupError(error instanceof Error ? error.message : "Failed to configure server setup.");
        setSetupMode("create");
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

  // Creates credentials that are always encrypted at rest, then moves on to
  // pairing. The secret is minted here rather than earlier so its lifetime
  // matches the QR that carries it, and because the QR has to carry the age
  // key the record will be sealed to.
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
          setSetupError("OS keyring is unavailable. Restart the desktop app and try again.");
          return;
        }
        keySource = { wrap: "device", deviceKey };
      }
      const created = await createIdentity({ keySource, deviceName });
      saveIdentityRecord(created);
      setIdentityRecord(created);
      const unlocked = await unlockIdentity(created, keySource);
      setIdentity(unlocked);
      setPairingSecret(await createPairingSecret());
      setSetupMode("tailnetPairing");
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
      await ensureTailnetJoined(unlocked, loadSetupConfigRecord()?.ca);
      setIdentity(unlocked);
      setSetupMode("rehydrating");
      setPasswordInput("");
    } catch (error) {
      setSetupError(error instanceof Error ? error.message : "Incorrect password.");
    }
  }, [ensureTailnetJoined, identityRecord, passwordInput]);

  // Waits for the deployment to authorize this device, then joins its tailnet.
  //
  // Everything the device needs arrives in one sealed record: the CA to trust
  // and where headscale is. Until that record appears the device has no way to
  // reach anything, which is why this is a poll rather than a request. The
  // record only opens under this device's pairing secret, which is what stops
  // a planted record from naming someone else's CA.
  useEffect(() => {
    if (setupMode !== "tailnetPairing" || !identity || !pairingSecret) {
      return;
    }

    const controller = new AbortController();
    pairingAbort.current = controller;

    void (async () => {
      try {
        const discoveryBase = (await window.replycantDesktop?.discoveryBaseUrl?.()) ?? undefined;
        const sealed = await pollForPairingRecord({
          slot: pairingSecret.slot,
          discoveryBase,
          signal: controller.signal,
        });
        const payload = await openPairingRecord(pairingSecret.encoded, sealed);

        const tailnetRecord = toTailnetConfigRecord(payload);
        // No key: the authorizing device committed this device's key before
        // publishing the record, so the sidecar mints its own from hsproxy.
        await joinTailnet({
          record: tailnetRecord,
          caPem: payload.caPem,
          identity,
        });

        const config: SetupConfigRecord = { ca: payload.caPem, url: gitdTailnetUrl() };
        await configureProxy(config);

        // Persisted only after the tailnet is actually up and the proxy has
        // accepted the config, so a failed attempt leaves nothing behind for
        // the next start to trust.
        saveTailnetConfigRecord(tailnetRecord);
        saveSetupConfigRecord(config);

        if (controller.signal.aborted) {
          return;
        }
        setPairingSecret(null);
        setSetupMode("rehydrating");
      } catch (error) {
        if (controller.signal.aborted) {
          return;
        }
        // The secret is kept so the QR stays on screen and the user can retry
        // the same attempt rather than having the operator rescan.
        setSetupError(
          error instanceof Error ? error.message : "Failed to pair this device over the tailnet.",
        );
      }
    })();

    return () => {
      controller.abort();
      pairingAbort.current = null;
    };
  }, [configureProxy, identity, pairingSecret, setupMode]);

  // Discards this device's identity and pairing so it can be paired afresh.
  const handleStartOver = useCallback(() => {
    pairingAbort.current?.abort();
    clearSetupConfigRecord();
    clearTailnetConfigRecord();
    clearIdentityRecord();
    void window.replycantDesktop?.clearIdentityKey?.().catch(() => {
      // Clearing is best-effort; local identity record removal is the durable reset.
    });
    // Leaving the tailnet matters beyond tidiness: the node was authorized
    // against the identity being discarded here, so it must not keep running
    // with a credential the user has just walked away from.
    void window.replycantDesktop?.leaveTailnet?.().catch(() => {
      // Best-effort; the node also goes down when the app quits.
    });
    setSetupMode("create");
    setSetupError(null);
    setIdentityRecord(null);
    setIdentity(null);
    setPasswordInput("");
    setPairingSecret(null);
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
    passwordRequired,
    identityRecord,
    identity,
    mtlsHeaders,
    pairingSecret,
    setSetupMode,
    setSetupError,
    setPasswordInput,
    setDeviceNameInput,
    handleCreateIdentity,
    handleUnlockIdentity,
    handleStartOver,
    retryRehydration,
  };
};
