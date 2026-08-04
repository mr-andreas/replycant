import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { IdentityKeyStore, type SafeStorageLike } from "./identityKeyStore";

// Builds an in-memory safeStorage stand-in so keystore tests never load Electron.
const createFakeSafeStorage = (options?: {
  available?: boolean;
  backend?: string;
}): SafeStorageLike => {
  const available = options?.available ?? true;
  const backend = options?.backend ?? "gnome_libsecret";
  return {
    isEncryptionAvailable: () => available,
    getSelectedStorageBackend: () => backend,
    encryptString: (plainText: string) => {
      if (!available) throw new Error("encryption unavailable");
      return Buffer.from(`enc:${plainText}`, "utf8");
    },
    decryptString: (encrypted: Buffer) => {
      const text = encrypted.toString("utf8");
      if (!text.startsWith("enc:")) throw new Error("invalid ciphertext");
      return text.slice(4);
    },
  };
};

describe("IdentityKeyStore", () => {
  let storeDir = "";

  afterEach(() => {
    if (storeDir) {
      rmSync(storeDir, { recursive: true, force: true });
      storeDir = "";
    }
  });

  // Ensures a fresh install mints a key and subsequent loads return the same bytes.
  it("creates then reloads the same device key", () => {
    storeDir = mkdtempSync(join(tmpdir(), "replycant-identity-key-"));
    const safeStorage = createFakeSafeStorage();
    const first = new IdentityKeyStore({ safeStorage, storeDir });
    const created = first.loadOrCreate();
    expect(created).toHaveLength(32);
    expect(existsSync(join(storeDir, "identityKey.bin"))).toBe(true);

    const second = new IdentityKeyStore({ safeStorage, storeDir });
    const reloaded = second.loadOrCreate();
    expect(Buffer.from(reloaded).equals(Buffer.from(created))).toBe(true);
  });

  // Start-over must discard the OS-wrapped key so a new identity cannot reuse it.
  it("clears the persisted device key file", () => {
    storeDir = mkdtempSync(join(tmpdir(), "replycant-identity-key-"));
    const safeStorage = createFakeSafeStorage();
    const store = new IdentityKeyStore({ safeStorage, storeDir });
    store.loadOrCreate();
    const keyPath = join(storeDir, "identityKey.bin");
    expect(existsSync(keyPath)).toBe(true);
    store.clear();
    expect(existsSync(keyPath)).toBe(false);
    store.clear();
  });

  // Rejects Chromium basic_text so Linux without a real keyring falls back to passwords.
  it("treats basic_text backend as unavailable", () => {
    storeDir = mkdtempSync(join(tmpdir(), "replycant-identity-key-"));
    const safeStorage = createFakeSafeStorage({ backend: "basic_text" });
    const store = new IdentityKeyStore({ safeStorage, storeDir });
    expect(store.isAvailable()).toBe(false);
    expect(() => store.loadOrCreate()).toThrow(/unavailable/i);
    expect(existsSync(join(storeDir, "identityKey.bin"))).toBe(false);
  });

  // Never write plaintext when the OS reports encryption is off.
  it("refuses to persist when encryption is unavailable", () => {
    storeDir = mkdtempSync(join(tmpdir(), "replycant-identity-key-"));
    const safeStorage = createFakeSafeStorage({ available: false });
    const store = new IdentityKeyStore({ safeStorage, storeDir });
    expect(store.isAvailable()).toBe(false);
    expect(() => store.loadOrCreate()).toThrow(/unavailable/i);
    expect(existsSync(join(storeDir, "identityKey.bin"))).toBe(false);
  });

  // Corrupted key files should fail closed rather than minting a new silent key.
  it("rejects a stored key with the wrong length", () => {
    storeDir = mkdtempSync(join(tmpdir(), "replycant-identity-key-"));
    const safeStorage = createFakeSafeStorage();
    const keyPath = join(storeDir, "identityKey.bin");
    writeFileSync(keyPath, safeStorage.encryptString(Buffer.from("short").toString("base64")));
    const store = new IdentityKeyStore({ safeStorage, storeDir });
    expect(() => store.loadOrCreate()).toThrow(/invalid length/i);
    // Ensure we did not overwrite the bad file with a fresh key during the failed load.
    expect(readFileSync(keyPath).equals(safeStorage.encryptString(Buffer.from("short").toString("base64")))).toBe(
      true,
    );
  });
});
