// Registers the browser's mTLS identity with the local proxy for the lifetime
// of a session.
//
// Most proxy routes authenticate with per-request `x-replycant-client-*`
// headers, but a `<video>` element cannot set request headers. Direct-play
// videos therefore rely on the proxy holding the identity against an httpOnly
// session cookie. The proxy keeps that material in memory only, so a proxy
// restart requires re-registration; `resetProxySession` exists for that
// recovery path.

const SESSION_ENDPOINT = "/api/setup/session";

let registeredFingerprint: string | null = null;
let inFlight: Promise<void> | null = null;

// Sends the identity to the proxy, which mints the session cookie in response.
const registerSession = async (mtlsHeaders: Record<string, string>): Promise<void> => {
  const response = await fetch(SESSION_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify(mtlsHeaders),
  });
  if (!response.ok) {
    throw new Error(`Failed to register proxy session (status ${response.status}).`);
  }
};

// Ensures the proxy holds current identity material, registering at most once
// per identity. Rejects if registration fails, and leaves nothing cached so the
// next call retries.
export const ensureProxySession = async (mtlsHeaders: Record<string, string> | null): Promise<void> => {
  if (!mtlsHeaders) return;

  const fingerprint = JSON.stringify(mtlsHeaders);
  if (registeredFingerprint === fingerprint) return;
  if (inFlight) return inFlight;

  inFlight = registerSession(mtlsHeaders)
    .then(() => {
      registeredFingerprint = fingerprint;
    })
    .finally(() => {
      inFlight = null;
    });
  return inFlight;
};

// Discards the cached registration so the next call re-establishes a session.
export const resetProxySession = (): void => {
  registeredFingerprint = null;
  inFlight = null;
};
