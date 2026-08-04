import { mkdirSync, readFileSync, unlinkSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomBytes } from "node:crypto";

const DEVICE_KEY_BYTES = 32;
const KEY_FILE_NAME = "identityKey.bin";

// Narrow safeStorage surface so unit tests can inject a fake without loading Electron.
export interface SafeStorageLike {
  isEncryptionAvailable: () => boolean;
  encryptString: (plainText: string) => Buffer;
  decryptString: (encrypted: Buffer) => string;
  getSelectedStorageBackend?: () => string;
}

export interface IdentityKeyStoreDeps {
  safeStorage: SafeStorageLike;
  storeDir: string;
}

// Rejects Chromium's basic_text backend: it obfuscates with a hardcoded key and
// is not real OS keyring protection, so Electron should fall back to passwords.
const isStrongEncryptionAvailable = (safeStorage: SafeStorageLike): boolean => {
  if (!safeStorage.isEncryptionAvailable()) return false;
  const backend = safeStorage.getSelectedStorageBackend?.();
  if (backend === "basic_text") return false;
  return true;
};

// Owns the OS-wrapped AES device key so identity ciphertext in localStorage
// cannot be decrypted from a stolen Chromium profile alone.
export class IdentityKeyStore {
  private readonly safeStorage: SafeStorageLike;
  private readonly keyPath: string;

  constructor(deps: IdentityKeyStoreDeps) {
    this.safeStorage = deps.safeStorage;
    this.keyPath = join(deps.storeDir, KEY_FILE_NAME);
  }

  // Reports whether silent device-wrap is safe on this host.
  isAvailable(): boolean {
    return isStrongEncryptionAvailable(this.safeStorage);
  }

  // Loads the existing device key or creates one protected by the OS keyring.
  loadOrCreate(): Uint8Array {
    if (!this.isAvailable()) {
      throw new Error("OS keyring encryption is unavailable for identity device keys.");
    }
    mkdirSync(dirname(this.keyPath), { recursive: true });
    if (existsSync(this.keyPath)) {
      const encrypted = readFileSync(this.keyPath);
      const encoded = this.safeStorage.decryptString(encrypted);
      const key = Buffer.from(encoded, "base64");
      if (key.length !== DEVICE_KEY_BYTES) {
        throw new Error("Stored identity device key has an invalid length.");
      }
      return new Uint8Array(key);
    }
    const key = randomBytes(DEVICE_KEY_BYTES);
    const encrypted = this.safeStorage.encryptString(key.toString("base64"));
    writeFileSync(this.keyPath, encrypted, { mode: 0o600 });
    return new Uint8Array(key);
  }

  // Deletes the wrapped device key so "Start over" cannot reuse stale material.
  clear(): void {
    if (!existsSync(this.keyPath)) return;
    unlinkSync(this.keyPath);
  }
}
