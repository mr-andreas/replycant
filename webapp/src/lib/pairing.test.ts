import { describe, expect, it } from "vitest";
import {
  createPairingSecret,
  deriveSlot,
  openPairingRecord,
  parsePairingSecret,
} from "./pairing";
import fixture from "./pairing.fixture.json";

const decodeBase64 = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));

const sealed = decodeBase64(fixture.sealedBase64);

describe("pairing secrets", () => {
  // A fresh secret per attempt is what keeps slots unlinkable and stops an
  // abandoned attempt's record from being replayed against a later one.
  it("mints a distinct secret and slot each time", async () => {
    const first = await createPairingSecret();
    const second = await createPairingSecret();
    expect(first.encoded).not.toBe(second.encoded);
    expect(first.slot).not.toBe(second.slot);
  });

  // The slot goes in a DNS label, so it has to be hex and comfortably inside
  // the 63-octet limit.
  it("produces a DNS-safe slot", async () => {
    const { slot } = await createPairingSecret();
    expect(slot).toMatch(/^[0-9a-f]{32}$/);
  });

  // The writer derives the slot independently from the same secret, so a
  // disagreement here means records land where nobody is looking.
  it("derives the same slot the Go writer used", async () => {
    expect(await deriveSlot(parsePairingSecret(fixture.secret))).toBe(fixture.slot);
  });

  // A truncated scan would otherwise be zero-padded into a slot nobody ever
  // wrote to, surfacing much later as an unexplained pairing timeout.
  it("rejects a secret of the wrong length", () => {
    expect(() => parsePairingSecret("AAAA")).toThrow(/32 bytes/);
  });

  it("rejects a blank secret", () => {
    expect(() => parsePairingSecret("   ")).toThrow(/empty/);
  });

  it("rejects a secret that is not base64url", () => {
    expect(() => parsePairingSecret("!!!not base64!!!")).toThrow();
  });

  // The QR carries the raw-URL form, which has no padding.
  it("encodes secrets without base64 padding", async () => {
    const { encoded } = await createPairingSecret();
    expect(encoded).not.toContain("=");
    expect(parsePairingSecret(encoded)).toHaveLength(32);
  });
});

describe("openPairingRecord", () => {
  // The whole point of the format: a record produced by the Go writer has to
  // open in the browser. Every other test here is downstream of this one. It
  // carries no tailnet key: the paired device mints its own from hsproxy.
  it("opens a record written by the Go implementation", async () => {
    const payload = await openPairingRecord(fixture.secret, sealed);

    expect(payload).toEqual({
      headscaleUrl: fixture.payload.headscale_url,
      caPem: fixture.payload.ca_pem,
    });
  });

  // An attacker who learns the slot can plant bytes there. Without the secret
  // those bytes must not open, which is what makes publishing the slot as a
  // public hostname safe.
  it("refuses a record written under a different pairing secret", async () => {
    await expect(
      openPairingRecord(fixture.secret, decodeBase64(fixture.otherSecretSealedBase64)),
    ).rejects.toThrow(/did not open under this pairing secret/);
  });

  // Same check from the other direction: holding the record and the wrong
  // secret is equally useless.
  it("refuses to open a record with the wrong secret", async () => {
    await expect(openPairingRecord(fixture.otherSecret, sealed)).rejects.toThrow(
      /did not open under this pairing secret/,
    );
  });

  // Flipping a byte must fail authentication rather than yield garbage, since
  // the payload is about to be trusted as a CA and a control-plane address.
  it("refuses a tampered record", async () => {
    const tampered = new Uint8Array(sealed);
    tampered[tampered.length - 1] ^= 0x01;
    await expect(openPairingRecord(fixture.secret, tampered)).rejects.toThrow();
  });

  it("refuses a truncated record", async () => {
    await expect(openPairingRecord(fixture.secret, sealed.slice(0, 8))).rejects.toThrow();
  });

  it("refuses an empty record", async () => {
    await expect(openPairingRecord(fixture.secret, new Uint8Array())).rejects.toThrow();
  });
});
