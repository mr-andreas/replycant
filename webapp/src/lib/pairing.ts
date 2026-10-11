import { decryptAesGcmCombined, importAes256Key } from "../modules/gitdb/encryption";

// Client half of the discovery handshake, mirroring pkg/pairing in the Go tree.
//
// A device that has never paired knows nothing about the deployment: not the
// CA, and not where headscale lives. It shows a QR carrying a freshly minted
// pairing secret, then waits for gitd to publish a record that secret can
// open. The record carries no tailnet credential: the authorizing device
// commits this device's key to pubkeys/ first, so the sidecar mints its own
// key from hsproxy with the device certificate.
//
// The pairing secret is the whole protection. It proves the record was
// written in response to *this* QR. An attacker who learns the discovery slot
// still cannot plant a record, because the slot is derived from the secret
// but opening a record requires the secret itself. Nothing in the record is
// confidential, so there is no second layer.
//
// The wire format is fixed by the Go writer, so every constant here has to
// match pkg/pairing/pairing.go exactly. pairing.test.ts pins that with a
// record produced by the Go implementation.

// 32 bytes is far beyond brute force, which is affordable because the secret
// only ever travels inside a QR code shown on the user's own screen.
const SECRET_BYTES = 32;

// 16 bytes of digest keeps slots collision-free in practice while fitting well
// inside the 63-octet DNS label limit, since the slot is used as a subdomain.
const SLOT_DIGEST_BYTES = 16;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

// Domain separation. Deriving the slot and the wrap key with different info
// strings is what makes it safe to publish the slot as a hostname while the
// wrap key still authenticates records.
const HKDF_SALT = textEncoder.encode("replycant/discovery/v1");
const SLOT_INFO = textEncoder.encode("replycant/discovery-slot/v1");
const WRAP_KEY_INFO = textEncoder.encode("replycant/discovery-wrap/v1");
const CONTENT_KEY_ID = textEncoder.encode("replycant/discovery-content/v1");

// What the pairing device needs in order to join the tailnet and then reach
// gitd over it.
export interface PairingPayload {
  headscaleUrl: string;
  caPem: string;
}

// A pairing attempt in progress. The encoded form goes in the QR; the slot is
// where the record will appear. Both derive from the same secret, so the slot
// never has to be transmitted to anyone.
export interface PairingSecret {
  encoded: string;
  slot: string;
}

const toBytes = (value: ArrayBuffer): Uint8Array => new Uint8Array(value);

const toHex = (bytes: Uint8Array): string =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

// Raw URL base64 avoids padding and the characters that get mangled when a
// value ends up in a URL, matching Secret.String() on the Go side.
const encodeBase64Url = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

const decodeBase64Url = (encoded: string): Uint8Array => {
  const normalized = encoded.trim().replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
};

// Expands the secret into an independent key for one purpose.
const derive = async (secret: Uint8Array, info: Uint8Array, lengthBytes: number): Promise<Uint8Array> => {
  const keyMaterial = await crypto.subtle.importKey("raw", secret as BufferSource, "HKDF", false, [
    "deriveBits",
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: HKDF_SALT as BufferSource, info: info as BufferSource },
    keyMaterial,
    lengthBytes * 8,
  );
  return toBytes(bits);
};

// Derives the subdomain the record is stored under. Writer and reader derive it
// independently, so the discovery API never learns who a record is for.
export const deriveSlot = async (secret: Uint8Array): Promise<string> =>
  toHex(await derive(secret, SLOT_INFO, SLOT_DIGEST_BYTES));

// Rejects a wrong length rather than zero-padding it, because a truncated scan
// would otherwise produce a slot nobody ever wrote to and surface as an
// unexplained pairing timeout.
export const parsePairingSecret = (encoded: string): Uint8Array => {
  const trimmed = encoded.trim();
  if (trimmed === "") {
    throw new Error("Pairing secret is empty.");
  }
  let raw: Uint8Array;
  try {
    raw = decodeBase64Url(trimmed);
  } catch {
    throw new Error("Pairing secret is not valid base64url.");
  }
  if (raw.length !== SECRET_BYTES) {
    throw new Error(`Pairing secret must be ${SECRET_BYTES} bytes, got ${raw.length}.`);
  }
  return raw;
};

// Mints a secret for one pairing attempt.
//
// A fresh secret per attempt is what keeps slots unlinkable and stops an
// abandoned attempt's record from being replayed against a later one.
export const createPairingSecret = async (): Promise<PairingSecret> => {
  const secret = crypto.getRandomValues(new Uint8Array(SECRET_BYTES));
  return { encoded: encodeBase64Url(secret), slot: await deriveSlot(secret) };
};

// Binds a record to its slot so a valid record cannot be relocated to another
// slot and replayed against a different pairing attempt.
const associatedData = (slot: string): Uint8Array => {
  const slotBytes = textEncoder.encode(slot);
  const combined = new Uint8Array(CONTENT_KEY_ID.length + slotBytes.length);
  combined.set(CONTENT_KEY_ID, 0);
  combined.set(slotBytes, CONTENT_KEY_ID.length);
  return combined;
};

interface WirePayload {
  headscale_url?: string;
  ca_pem?: string;
}

// Fails a payload that would leave the device stuck at "waiting for
// authorization" forever, naming what is absent so the cause is visible.
const toPayload = (wire: WirePayload): PairingPayload => {
  const fields: Array<[keyof WirePayload, keyof PairingPayload]> = [
    ["headscale_url", "headscaleUrl"],
    ["ca_pem", "caPem"],
  ];
  const payload: Partial<PairingPayload> = {};
  const missing: string[] = [];
  for (const [wireKey, payloadKey] of fields) {
    const value = wire[wireKey];
    if (typeof value !== "string" || value.trim() === "") {
      missing.push(wireKey);
      continue;
    }
    payload[payloadKey] = value;
  }
  if (missing.length > 0) {
    throw new Error(`Pairing payload is missing ${missing.join(", ")}.`);
  }
  return payload as PairingPayload;
};

// Opens a record fetched from the discovery API.
//
// The pairing secret is the whole credential: the ciphertext only opens under
// the secret from this device's QR.
export const openPairingRecord = async (
  secretEncoded: string,
  sealed: Uint8Array,
): Promise<PairingPayload> => {
  const secret = parsePairingSecret(secretEncoded);
  const slot = await deriveSlot(secret);
  const aad = associatedData(slot);

  const wrapKey = await importAes256Key(await derive(secret, WRAP_KEY_INFO, 32));

  let payloadJson: Uint8Array;
  try {
    payloadJson = await decryptAesGcmCombined(sealed, wrapKey, aad);
  } catch {
    throw new Error("Pairing record did not open under this pairing secret.");
  }

  let wire: WirePayload;
  try {
    wire = JSON.parse(textDecoder.decode(payloadJson)) as WirePayload;
  } catch {
    throw new Error("Pairing payload is not valid JSON.");
  }
  return toPayload(wire);
};
