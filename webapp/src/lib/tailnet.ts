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

// The port gitd serves Git and LFS on inside the tailnet.
//
// Pinned for the same reason as the control port below, and it must stay in
// step with the ports the headscale policy in docker-compose.yaml opens: a
// device that dials anything else is denied by the tailnet itself, not by gitd.
export const GITD_TAILNET_PORT = 8443;

// MagicDNS name gitd registers on the tailnet. Pinned rather than delivered
// in a pairing record so a QR and a certificate SAN cannot drift.
export const GITD_TAILNET_HOST = "gitd.replycant.internal";

// The URL gitd is reachable at once the device is on the tailnet.
//
// MagicDNS resolves this inside the tailnet, and gitd's certificate carries the
// matching SAN, so the existing mTLS transport works unchanged. The port is
// explicit because gitd's tailnet listener is not on 443, and an implied 443
// would leave every request timing out against a port nothing is bound to.
export const gitdTailnetUrl = (): string =>
  `https://${GITD_TAILNET_HOST}:${GITD_TAILNET_PORT}`;

// The port gitd relays control-plane traffic on inside the tailnet.
//
// Pinned here rather than delivered in the pairing record because it is a
// property of the gitd build, not of the deployment, and a device only ever
// talks to a gitd from the same release. Must match --tailnet-control-addr.
export const GITD_CONTROL_PORT = 8444;

// Where to reach the control plane from inside the tailnet.
//
// This is the path that lets a paired device stop depending on the hosted
// relay: gitd splices it through to the same hsproxy the relay leads to, so the
// device's TLS session is unchanged apart from the name it verifies.
export const gitdControlAddr = (): { addr: string; serverName: string } => ({
  addr: `${GITD_TAILNET_HOST}:${GITD_CONTROL_PORT}`,
  serverName: GITD_TAILNET_HOST,
});

export const toTailnetConfigRecord = (payload: PairingPayload): TailnetConfigRecord => {
  const { addr, serverName } = toHeadscaleAddr(payload.headscaleUrl);
  return {
    headscaleAddr: addr,
    headscaleServerName: serverName,
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
      typeof parsed.headscaleServerName !== "string"
    ) {
      return null;
    }
    return {
      headscaleAddr: parsed.headscaleAddr,
      headscaleServerName: parsed.headscaleServerName,
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
 *
 * No join key is passed: the desktop is never a deployment's first device, so
 * its key is already in `pubkeys/` and the sidecar mints its own from hsproxy.
 */
export const joinTailnet = async ({
  record,
  caPem,
  identity,
}: JoinTailnetOptions): Promise<void> => {
  const desktop = window.replycantDesktop;
  if (!desktop?.joinTailnet) {
    throw new Error("This build cannot join a tailnet. Use the desktop app to pair over a tailnet.");
  }
  const control = gitdControlAddr();
  await desktop.joinTailnet({
    headscaleAddr: record.headscaleAddr,
    headscaleServerName: record.headscaleServerName,
    // Where the sidecar should look for the control plane once the node is up,
    // so later reconnects stop crossing the hosted relay.
    gitdControlAddr: control.addr,
    gitdControlServerName: control.serverName,
    caPem,
    clientCertPem: identity.certificatePem,
    clientKeyPem: identity.privateKeyPem,
    hostname: identity.deviceName,
  });
};
