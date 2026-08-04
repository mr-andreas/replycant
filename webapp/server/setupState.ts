import { ProxyConfig } from "./config";
import { MtlsMaterial } from "./proxy";

// Captures setup payload returned by caserver discovery so frontend and proxy can share one schema.
export interface DiscoveredServerConfig {
  ca: string;
  url: string;
}

// Defines mutable proxy setup state so runtime discovery can reconfigure upstream TLS and endpoints.
export interface SetupState {
  getConfig: () => Pick<ProxyConfig, "upstreamCa" | "gitBaseUrl" | "lfsBaseUrl">;
  setDiscoveredConfig: (config: DiscoveredServerConfig) => void;
  setConfig: (config: Pick<ProxyConfig, "upstreamCa" | "gitBaseUrl" | "lfsBaseUrl">) => void;
  isConfigured: () => boolean;
  setSessionMtlsMaterial: (sessionId: string, material: MtlsMaterial) => void;
  getSessionMtlsMaterial: (sessionId: string | undefined) => MtlsMaterial | undefined;
}

// Derives the LFS proxy base from the configured git base URL so both protocols share one origin.
export const deriveLfsBaseUrl = (gitBaseUrl: string): string => {
  const parsed = new URL(gitBaseUrl);
  return `${parsed.protocol}//${parsed.host}/lfs`;
};

// Stores runtime-discovered proxy configuration in-memory so setup stays browser-owned and ephemeral.
export const createSetupState = (
  seed: Pick<ProxyConfig, "upstreamCa" | "gitBaseUrl" | "lfsBaseUrl"> = {},
): SetupState => {
  let current = { ...seed };

  // Media element requests cannot carry per-request mTLS headers, so each
  // browser registers its identity once and the proxy keys it by session.
  // Keeping this in memory means a proxy restart forces re-registration rather
  // than leaving private key material on disk.
  const sessionMtlsMaterial = new Map<string, MtlsMaterial>();

  // Returns current in-memory setup values for routes and forwarder lookups.
  const getConfig = () => ({ ...current });

  // Normalizes discovery response fields into proxy config keys.
  const setDiscoveredConfig = (config: DiscoveredServerConfig) => {
    current = {
      upstreamCa: config.ca,
      gitBaseUrl: config.url,
      lfsBaseUrl: deriveLfsBaseUrl(config.url),
    };
  };

  // Stores validated setup values pushed by the browser.
  const setConfig = (config: Pick<ProxyConfig, "upstreamCa" | "gitBaseUrl" | "lfsBaseUrl">) => {
    current = { ...config };
  };

  // Reports whether all required upstream setup fields are available for git/lfs proxying.
  const isConfigured = () =>
    Boolean(current.upstreamCa && current.gitBaseUrl && current.lfsBaseUrl);

  return {
    getConfig,
    setDiscoveredConfig,
    setConfig,
    isConfigured,
    setSessionMtlsMaterial: (sessionId, material) => {
      sessionMtlsMaterial.set(sessionId, material);
    },
    getSessionMtlsMaterial: (sessionId) => (sessionId ? sessionMtlsMaterial.get(sessionId) : undefined),
  };
};
