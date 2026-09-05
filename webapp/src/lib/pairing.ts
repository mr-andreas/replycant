import { decryptAesGcmCombined, decryptAgeEnvelope, importAes256Key } from "../modules/gitdb/encryption";

// Client half of the discovery handshake, mirroring pkg/pairing in the Go tree.
//
// A device that has never paired knows nothing about the deployment: not the
// CA, not where headscale lives, and it holds no tailnet credential. It shows a
// QR carrying its own age public key plus a freshly minted pairing secret, then
// waits for gitd to publish a record it alone can open.
//
// Both halves of that record matter. The pairing secret proves the record was
// written in response to *this* QR, and the age key proves the record was
// written for *this* device. An attacker who learns the discovery slot still
// cannot plant a record, because the slot is derived from the secret but
// opening a record requires the secret itself.
//
// The wire format is fixed by the Go writer, so every constant here has to
// match pkg/pairing/pairing.go exactly. pairing.crossLanguage.test.ts pins that
// with a record produced by the Go implementation.

// 32 bytes is far beyond brute force, which is affordable because the secret
// only ever travels inside a QR code shown on the user's own screen.
const SECRET_BYTES = 32;

// 16 bytes of digest keeps slots collision-free in practice while fitting well
// inside the 63-octet DNS label limit, since the slot is used as a subdomain.
const SLOT_DIGEST_BYTES = 16;

// Bumped when the envelope layout changes, so an old client reports an
// unsupported version rather than a decryption failure that reads as
// corruption.
const ENVELOPE_VERSION = 1;

// Hex characters in a tunnel hostname's CA fingerprint label, truncated from a
// SHA-256 of the CA's DER. Must match caDNSLabelHexChars in pkg/gitcrypt, since
// the deployment registers the tunnel subdomain under exactly this label.
const CA_LABEL_HEX_CHARS = 32;

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
  preauthKey: string;
  gitdTailnetName: string;
  baseDomain: string;
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

const decodeBase64 = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded.trim()), (character) => character.charCodeAt(0));

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

interface WireEnvelope {
  v?: number;
  age?: string;
  payload?: string;
}

interface WirePayload {
  headscale_url?: string;
  ca_pem?: string;
  preauth_key?: string;
  gitd_tailnet_name?: string;
  base_domain?: string;
}

// Fails a payload that would leave the device stuck at "waiting for
// authorization" forever, naming what is absent so the cause is visible.
const toPayload = (wire: WirePayload): PairingPayload => {
  const fields: Array<[keyof WirePayload, keyof PairingPayload]> = [
    ["headscale_url", "headscaleUrl"],
    ["ca_pem", "caPem"],
    ["preauth_key", "preauthKey"],
    ["gitd_tailnet_name", "gitdTailnetName"],
    ["base_domain", "baseDomain"],
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
// Both credentials are required by construction: the outer AEAD only opens
// under the pairing secret, and the inner content key only unwraps with the
// device's age key. Neither alone is enough to read a record.
export const openPairingRecord = async (
  secretEncoded: string,
  agePrivateKeyBase64: string,
  sealed: Uint8Array,
): Promise<PairingPayload> => {
  const secret = parsePairingSecret(secretEncoded);
  const slot = await deriveSlot(secret);
  const aad = associatedData(slot);

  const wrapKey = await importAes256Key(await derive(secret, WRAP_KEY_INFO, 32));

  let inner: Uint8Array;
  try {
    inner = await decryptAesGcmCombined(sealed, wrapKey, aad);
  } catch {
    // Almost always a record written for a different pairing attempt, which is
    // worth distinguishing from a device-key mismatch below.
    throw new Error("Pairing record did not open under this pairing secret.");
  }

  let envelope: WireEnvelope;
  try {
    envelope = JSON.parse(textDecoder.decode(inner)) as WireEnvelope;
  } catch {
    throw new Error("Pairing envelope is not valid JSON.");
  }
  if (envelope.v !== ENVELOPE_VERSION) {
    throw new Error(
      `Unsupported pairing envelope version ${String(envelope.v)} (expected ${ENVELOPE_VERSION}).`,
    );
  }
  if (!envelope.age || !envelope.payload) {
    throw new Error("Pairing envelope is missing its wrapped key or payload.");
  }

  const contentKey = await decryptAgeEnvelope(decodeBase64(envelope.age), agePrivateKeyBase64);
  const payloadJson = await decryptAesGcmCombined(
    decodeBase64(envelope.payload),
    await importAes256Key(contentKey),
    aad,
  );

  return toPayload(JSON.parse(textDecoder.decode(payloadJson)) as WirePayload);
};

// Confirms the delivered CA is the one the headscale hostname commits to.
//
// In tunnel mode the hostname's first label is a fingerprint of the CA, giving
// the device a second check, independent of the record's encryption, that it is
// about to trust the CA the hostname names. Manual-exposure hostnames carry no
// fingerprint, so there is nothing to compare and this passes.
export const verifyCALabel = async (payload: PairingPayload): Promise<void> => {
  let host: string;
  try {
    host = new URL(payload.headscaleUrl.trim()).hostname;
  } catch {
    throw new Error("Headscale URL in the pairing record is not a valid URL.");
  }
  const label = host.split(".")[0]?.toLowerCase() ?? "";
  if (!new RegExp(`^[0-9a-f]{${CA_LABEL_HEX_CHARS}}$`).test(label)) {
    return;
  }

  const der = decodeBase64(
    payload.caPem
      .replace(/-----BEGIN CERTIFICATE-----/g, "")
      .replace(/-----END CERTIFICATE-----/g, "")
      .replace(/\s+/g, ""),
  );
  const digest = toHex(toBytes(await crypto.subtle.digest("SHA-256", der as BufferSource))).slice(
    0,
    CA_LABEL_HEX_CHARS,
  );
  if (digest !== label) {
    throw new Error("The pairing record's CA does not match the fingerprint in the headscale hostname.");
  }
};
