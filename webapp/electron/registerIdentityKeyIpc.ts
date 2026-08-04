import type { IpcMain } from "electron";
import { IdentityKeyStore, type SafeStorageLike } from "./identityKeyStore";

// Registers identity-key IPC once so production and dev Electron shells stay in sync.
export const registerIdentityKeyIpc = (
  ipcMain: IpcMain,
  deps: { safeStorage: SafeStorageLike; storeDir: string },
): IdentityKeyStore => {
  const store = new IdentityKeyStore(deps);

  ipcMain.handle("identityKey:available", () => store.isAvailable());

  // Returns the device key as base64 so the sandboxed renderer never touches the key file.
  ipcMain.handle("identityKey:get", () => {
    const key = store.loadOrCreate();
    return Buffer.from(key).toString("base64");
  });

  ipcMain.handle("identityKey:clear", () => {
    store.clear();
  });

  return store;
};
