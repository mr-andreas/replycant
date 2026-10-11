// Reader side of the discovery handshake.
//
// A pairing device has nothing to talk to yet, so it cannot be told when its
// record is ready. It polls its own slot instead, which is derived from the
// pairing secret in the QR it is displaying and is therefore known only to the
// device and to whoever scanned it.
//
// Polling is deliberately plain: the record is opaque and single-use, so a
// wasted read costs nothing and a missed one just means another attempt.

// Origin records are published under. The slot goes in front of its host as
// a subdomain, so a record's address never appears in a request path or query
// where it could be logged by an intermediary.
export const DEFAULT_DISCOVERY_BASE = "https://discovery.replycant.com";

// How often to ask. gitd publishes as soon as the operator approves the device,
// which is a human action, so a tight interval buys nothing but load.
const DEFAULT_INTERVAL_MS = 2_000;

// How long to keep waiting before giving up. The record's own TTL is ten
// minutes, so waiting longer than that could only ever return nothing.
const DEFAULT_TIMEOUT_MS = 10 * 60_000;

export interface PollForPairingRecordOptions {
  // Derived from the pairing secret, so the caller already has it and this
  // never has to be transmitted.
  slot: string;

  // A whole origin rather than a host, so a test can point at a plain-HTTP
  // fake on its own port.
  discoveryBase?: string;
  intervalMs?: number;
  timeoutMs?: number;

  // Lets the user abandon a pairing attempt, and lets tests drive the loop.
  signal?: AbortSignal;

  fetchImpl?: typeof fetch;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
}

const defaultSleep = (ms: number, signal?: AbortSignal): Promise<void> =>
  new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DOMException("Aborted", "AbortError"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });

export const pairingRecordUrl = (slot: string, discoveryBase = DEFAULT_DISCOVERY_BASE): string => {
  const base = new URL(discoveryBase);
  return `${base.protocol}//${slot}.${base.host}/`;
};

/**
 * Waits for the sealed pairing record to appear in a slot.
 *
 * Resolves with the record's raw bytes; the caller decrypts it, because this
 * layer must never be in a position to read one.
 *
 * A 404 is the expected answer for most of a pairing attempt: it means the
 * operator has not approved the device yet. Anything else is reported, since a
 * misconfigured discovery host would otherwise look identical to a user who is
 * simply slow to approve.
 */
export const pollForPairingRecord = async ({
  slot,
  discoveryBase = DEFAULT_DISCOVERY_BASE,
  intervalMs = DEFAULT_INTERVAL_MS,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  signal,
  fetchImpl = fetch,
  sleep = defaultSleep,
}: PollForPairingRecordOptions): Promise<Uint8Array> => {
  const url = pairingRecordUrl(slot, discoveryBase);
  const deadline = Date.now() + timeoutMs;

  for (;;) {
    if (signal?.aborted) {
      throw new DOMException("Aborted", "AbortError");
    }

    // Network errors are tolerated the same way a 404 is: a device may be
    // pairing over a connection that is still coming up.
    let response: Response | null = null;
    try {
      response = await fetchImpl(url, { method: "GET", cache: "no-store", signal });
    } catch (error) {
      if (signal?.aborted) {
        throw error;
      }
    }

    if (response?.ok) {
      return new Uint8Array(await response.arrayBuffer());
    }
    if (response && response.status !== 404) {
      throw new Error(
        `Discovery service returned ${response.status} while waiting for the pairing record.`,
      );
    }

    if (Date.now() + intervalMs > deadline) {
      throw new Error(
        "Timed out waiting for the server to approve this device. Start pairing again to retry.",
      );
    }
    await sleep(intervalMs, signal);
  }
};
