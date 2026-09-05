import type { DecryptedIdentity } from "../modules/gitdb";
import type { PairingPayload } from "./pairing";

// Desktop tailnet membership, from the renderer's side.
//
// The tailnet node itself lives in the main process, because it is a spawned Go
// binary and the renderer is sandboxed. What the renderer owns is the decision
// to join and the credentials to join with, which is why this module exists:
// it turns a decrypted pairing record into a join request, and remembers just
// enough to rejoin after a restart.

// Where the tailnet coordinates are kept between runs.
//
// Deliberately separate from the setup config: a deployment can be reachable
// over a tailnet, over the LAN, or both, and losing one should not invalidate
// the other.
export const TAILNET_CONFIG_STORAGE_KEY = "replycant.tailnet.config";

// What has to survive a restart in order to rejoin.
//
// Notably absent is the pre-auth key. It is single-use and expires in minutes,
// and the node's own key material persists in the sidecar's state directory, so
// a rejoin needs no credential beyond the device's existing identity. Storing
// it would be a durable copy of a credential for no benefit.
export interface TailnetConfigRecord {
  headscaleAddr: string;
  headscaleServerName: string;

  // MagicDNS name and base domain, kept so the gitd URL can be rebuilt without
  // reopening the pairing record.
  gitdTailnetName: string;
  baseDomain: string;
}

// Derives the dial target for headscale's control plane.
//
// The sidecar dials a host and port rather than a URL because it speaks TLS
// directly to hsproxy; the URL form only exists because that is how headscale
// advertises itself.
export const toHeadscaleAddr = (headscaleUrl: string): { addr: string; serverName: string } => {
  let parsed: URL;
  try {
    parsed = new URL(headscaleUrl.trim());
  } catch {
    throw new Error("Headscale URL in the pairing record is not a valid URL.");
  }
  if (!parsed.hostname) {
    throw new Error("Headscale URL in the pairing record has no hostname.");
  }
  const port = parsed.port || (parsed.protocol === "http:" ? "80" : "443");
  return { addr: `${parsed.hostname}:${port}`, serverName: parsed.hostname };
};

// The URL gitd is reachable at once the device is on the tailnet.
//
// MagicDNS resolves this inside the tailnet, and gitd's certificate carries the
// matching SAN, so the existing mTLS transport works unchanged.
export const gitdTailnetUrl = (record: Pick<TailnetConfigRecord, "gitdTailnetName" | "baseDomain">): string =>
  `https://${record.gitdTailnetName}.${record.baseDomain}`;

export const toTailnetConfigRecord = (payload: PairingPayload): TailnetConfigRecord => {
  const { addr, serverName } = toHeadscaleAddr(payload.headscaleUrl);
  return {
    headscaleAddr: addr,
    headscaleServerName: serverName,
    gitdTailnetName: payload.gitdTailnetName,
    baseDomain: payload.baseDomain,
  };
};

export const saveTailnetConfigRecord = (record: TailnetConfigRecord): void => {
  localStorage.setItem(TAILNET_CONFIG_STORAGE_KEY, JSON.stringify(record));
};

// Returns null rather than throwing on anything unexpected, so a corrupted
// entry degrades to "not on a tailnet" instead of blocking startup entirely.
export const loadTailnetConfigRecord = (): TailnetConfigRecord | null => {
  const raw = localStorage.getItem(TAILNET_CONFIG_STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<TailnetConfigRecord>;
    if (
      typeof parsed.headscaleAddr !== "string" ||
      typeof parsed.headscaleServerName !== "string" ||
      typeof parsed.gitdTailnetName !== "string" ||
      typeof parsed.baseDomain !== "string"
    ) {
      return null;
    }
    return {
      headscaleAddr: parsed.headscaleAddr,
      headscaleServerName: parsed.headscaleServerName,
      gitdTailnetName: parsed.gitdTailnetName,
      baseDomain: parsed.baseDomain,
    };
  } catch {
    return null;
  }
};

export const clearTailnetConfigRecord = (): void => {
  localStorage.removeItem(TAILNET_CONFIG_STORAGE_KEY);
};

// Reports whether this build can join a tailnet at all.
//
// Only the desktop shell can: joining means running a userspace WireGuard node,
// which needs a native binary the browser build has no way to host. The browser
// build therefore stays on the LAN path.
export const tailnetSupported = (): boolean => typeof window.replycantDesktop?.joinTailnet === "function";

export interface JoinTailnetOptions {
  record: TailnetConfigRecord;
  caPem: string;
  identity: Pick<DecryptedIdentity, "privateKeyPem" | "certificatePem" | "deviceName">;

  // Only present on a first join. A rejoin reuses the node persisted in the
  // sidecar's state directory.
  preauthKey?: string;
}

/**
 * Brings the desktop tailnet node up.
 *
 * The device presents the same self-signed certificate it already uses for
 * gitd, because hsproxy authorizes by public key against the deployment's
 * authorized-key list rather than by certificate chain. That means revoking a
 * device removes its tailnet access too, with no second credential to track.
 *
 * The CA is pinned for the other direction: it is what proves the control plane
 * on the far side of the tunnel is really this deployment's.
 */
export const joinTailnet = async ({
  record,
  caPem,
  identity,
  preauthKey,
}: JoinTailnetOptions): Promise<void> => {
  const desktop = window.replycantDesktop;
  if (!desktop?.joinTailnet) {
    throw new Error("This build cannot join a tailnet. Use the desktop app to pair over a tailnet.");
  }
  await desktop.joinTailnet({
    headscaleAddr: record.headscaleAddr,
    headscaleServerName: record.headscaleServerName,
    caPem,
    clientCertPem: identity.certificatePem,
    clientKeyPem: identity.privateKeyPem,
    ...(preauthKey ? { preauthKey } : {}),
    hostname: identity.deviceName,
  });
};
