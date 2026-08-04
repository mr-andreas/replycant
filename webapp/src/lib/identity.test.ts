import { beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";
import { X509CertificateGenerator } from "@peculiar/x509";

vi.mock("@peculiar/x509", () => ({
  KeyUsageFlags: { digitalSignature: 1, keyEncipherment: 2 },
  KeyUsagesExtension: class {},
  SubjectKeyIdentifierExtension: {
    create: vi.fn(async () => ({})),
  },
  X509CertificateGenerator: {
    createSelfSigned: vi.fn(async () => ({ rawData: new TextEncoder().encode("fake-cert").buffer })),
  },
  PemConverter: {
    encode: vi.fn(() => "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"),
  },
}));

import {
  buildPublicKeyQrPayload,
  buildMtlsHeaders,
  clearIdentityRecord,
  computeCaHash,
  createIdentity,
  createDeviceUuid,
  getDefaultDeviceName,
  IDENTITY_STORAGE_KEY,
  loadIdentityRecord,
  sanitizeDeviceName,
  saveIdentityRecord,
  unlockIdentity,
} from "./identity";

// Builds a deterministic 32-byte device key so device-wrap tests stay repeatable.
const deviceKey = () => new Uint8Array(32).fill(7);

// Resets storage between tests so identity lifecycle assertions remain deterministic.
const resetStorage = () => {
  clearIdentityRecord();
};

describe("identity lifecycle", () => {
  beforeEach(() => {
    resetStorage();
  });

  // Ensures password-wrapped records never leave private material in localStorage.
  it("creates a password-wrapped identity without plaintext secrets at rest", async () => {
    const record = await createIdentity({
      keySource: { wrap: "password", password: "secret" },
      deviceName: "Phone Browser",
    });
    expect(record.version).toBe(2);
    expect(record.wrap).toBe("password");
    expect(record.saltBase64).toBeTruthy();
    expect(JSON.stringify(record)).not.toContain("PRIVATE KEY");
    expect(JSON.stringify(record)).not.toContain("agePrivateKeyBase64");
    saveIdentityRecord(record);
    const storedRaw = localStorage.getItem(IDENTITY_STORAGE_KEY)!;
    expect(storedRaw).not.toContain("PRIVATE KEY");
    expect(storedRaw).not.toContain("BEGIN CERTIFICATE");
    const stored = loadIdentityRecord();
    await expect(unlockIdentity(stored!, { wrap: "password", password: "wrong" })).rejects.toThrow();
    const unlocked = await unlockIdentity(stored!, { wrap: "password", password: "secret" });
    expect(unlocked.certificatePem.includes("BEGIN CERTIFICATE")).toBe(true);
    expect(unlocked.agePrivateKeyBase64.length).toBeGreaterThan(0);
  });

  // Ensures Electron device-wrap encrypts with the OS-backed key and unlocks silently.
  it("creates and unlocks a device-wrapped identity", async () => {
    const key = deviceKey();
    const record = await createIdentity({
      keySource: { wrap: "device", deviceKey: key },
      deviceName: "Laptop Browser",
      deviceUUID: "abc-123",
    });
    expect(record.version).toBe(2);
    expect(record.wrap).toBe("device");
    expect(record.deviceName).toBe("laptop-browser");
    expect(record.deviceUUID).toBe("abc-123");
    expect(record.agePublicKey.startsWith("age1")).toBe(true);
    expect(record.saltBase64).toBeUndefined();
    expect(JSON.stringify(record)).not.toContain("PRIVATE KEY");
    saveIdentityRecord(record);
    const stored = loadIdentityRecord();
    expect(stored?.publicKeySsh.startsWith("ecdsa-sha2-nistp256 ")).toBe(true);
    const unlocked = await unlockIdentity(stored!, { wrap: "device", deviceKey: key });
    const headers = buildMtlsHeaders(unlocked);
    expect(headers["x-replycant-client-key"]).toBeTruthy();
    expect(headers["x-replycant-client-cert"]).toBeTruthy();
  });

  // Surfaces a clear failure when the OS keyring no longer yields the device key.
  it("fails device unlock when the device key is unavailable", async () => {
    const record = await createIdentity({
      keySource: { wrap: "device", deviceKey: deviceKey() },
      deviceName: "desktop",
    });
    await expect(
      unlockIdentity(record, { wrap: "device", deviceKey: null }),
    ).rejects.toThrow(/device key/i);
  });

  // Prevents the cleartext fallback that the security audit flagged.
  it("rejects identity creation without a password or device key", async () => {
    await expect(
      createIdentity({
        keySource: { wrap: "password", password: "" },
        deviceName: "browser",
      }),
    ).rejects.toThrow(/password/i);
    await expect(
      createIdentity({
        keySource: { wrap: "device", deviceKey: new Uint8Array(16) },
        deviceName: "browser",
      }),
    ).rejects.toThrow(/32/);
  });

  // Rejects pre-encryption v1 records so alpha installs re-onboard instead of migrating.
  it("rejects v1 and plaintext records from loadIdentityRecord", () => {
    localStorage.setItem(
      IDENTITY_STORAGE_KEY,
      JSON.stringify({
        version: 1,
        publicKeySsh: "ecdsa-sha2-nistp256 AAAA",
        agePublicKey: "age1fake",
        deviceName: "old",
        deviceUUID: "uuid-1",
        createdAt: new Date().toISOString(),
        encrypted: false,
        privateKeyPem: "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
        certificatePem: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
        agePrivateKeyBase64: "AAAA",
      }),
    );
    expect(loadIdentityRecord()).toBeNull();

    localStorage.setItem(
      IDENTITY_STORAGE_KEY,
      JSON.stringify({
        version: 2,
        publicKeySsh: "ecdsa-sha2-nistp256 AAAA",
        agePublicKey: "age1fake",
        deviceName: "bad",
        deviceUUID: "uuid-1",
        createdAt: new Date().toISOString(),
        wrap: "password",
        encryptedPayloadBase64: "AAAA",
        ivBase64: "AAAA",
        saltBase64: "AAAA",
        privateKeyPem: "-----BEGIN PRIVATE KEY-----\nLEAK\n-----END PRIVATE KEY-----\n",
      }),
    );
    expect(loadIdentityRecord()).toBeNull();
  });

  // loadIdentityRecord must not rewrite storage, so a rejected payload stays untouched.
  it("does not rewrite localStorage when loading an invalid record", () => {
    const raw = JSON.stringify({ version: 1, publicKeySsh: "x", agePublicKey: "y" });
    localStorage.setItem(IDENTITY_STORAGE_KEY, raw);
    expect(loadIdentityRecord()).toBeNull();
    expect(localStorage.getItem(IDENTITY_STORAGE_KEY)).toBe(raw);
  });

  it("builds iOS-compatible public key QR payload", async () => {
    const record = await createIdentity({
      keySource: { wrap: "password", password: "secret" },
      deviceName: "my-device",
      deviceUUID: "uuid-1",
    });
    const unlocked = await unlockIdentity(record, { wrap: "password", password: "secret" });
    const payload = JSON.parse(buildPublicKeyQrPayload(unlocked, "abc123")) as Record<string, string>;
    expect(payload.pubkey).toBe(unlocked.publicKeySsh);
    expect(payload.age_pubkey).toBe(unlocked.agePublicKey);
    expect(payload.name).toBe("my-device");
    expect(payload.uuid).toBe("uuid-1");
    expect(payload.ca_hash).toBe("abc123");
  });

  it("hashes canonical certificate bytes independent of PEM formatting", async () => {
    const compactPem = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\n-----END CERTIFICATE-----";
    const spacedPem = "-----BEGIN CERTIFICATE-----\nZmFrZS1jZXJ0\r\n-----END CERTIFICATE-----\n";
    const compactHash = await computeCaHash(compactPem);
    const spacedHash = await computeCaHash(spacedPem);
    expect(compactHash).toMatch(/^[a-f0-9]{64}$/);
    expect(compactHash).toBe(spacedHash);
  });

  it("normalizes empty device names and generated metadata helpers", () => {
    expect(sanitizeDeviceName("  ")).toBe("replycant-webapp");
    expect(getDefaultDeviceName()).toBeTruthy();
    expect(createDeviceUuid()).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
  });

  it("creates certificates with long-lived validity", async () => {
    const now = new Date();
    await createIdentity({
      keySource: { wrap: "password", password: "secret" },
      deviceName: "browser",
    });
    const createSelfSigned = vi.mocked(X509CertificateGenerator.createSelfSigned);
    expect(createSelfSigned).toHaveBeenCalled();
    const notAfter = createSelfSigned.mock.calls.at(-1)![0].notAfter!;
    expect(notAfter).toBeInstanceOf(Date);
    const validityYears = (notAfter.getTime() - now.getTime()) / (365 * 24 * 60 * 60 * 1000);
    expect(validityYears).toBeGreaterThan(99);
  });
});
