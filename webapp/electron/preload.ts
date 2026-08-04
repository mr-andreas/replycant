import { contextBridge, ipcRenderer } from "electron";

// Reads persisted page-state synchronously so restoration can happen before
// renderer startup logic selects default navigation.
const persistedLastPage = ipcRenderer.sendSync("lastPage:read") ?? null;

// Exposes desktop metadata and window control actions without enabling renderer Node access.
contextBridge.exposeInMainWorld("replycantDesktop", {
  platform: process.platform,
  minimize: () => ipcRenderer.invoke("window:minimize"),
  maximize: () => ipcRenderer.invoke("window:maximize"),
  close: () => ipcRenderer.invoke("window:close"),
  persistedLastPage,
  persistLastPage: (state: unknown) => ipcRenderer.sendSync("lastPage:write", state),
  // Lets the renderer use OS-keyring device wrap without reading the key file itself.
  identityKeyAvailable: () => ipcRenderer.invoke("identityKey:available") as Promise<boolean>,
  identityKey: () => ipcRenderer.invoke("identityKey:get") as Promise<string>,
  clearIdentityKey: () => ipcRenderer.invoke("identityKey:clear") as Promise<void>,
});
