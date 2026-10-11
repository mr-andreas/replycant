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
  // Onboarding hands over the pairing record's credentials; the tailnet node
  // itself lives in the main process so the renderer never sees the proxy.
  joinTailnet: (request: unknown) => ipcRenderer.invoke("tailnet:join", request) as Promise<void>,
  leaveTailnet: () => ipcRenderer.invoke("tailnet:leave") as Promise<void>,
  discoveryBaseUrl: () => ipcRenderer.invoke("tailnet:discoveryBaseUrl") as Promise<string | null>,
  tailnetStatus: () => ipcRenderer.invoke("tailnet:status") as Promise<unknown>,
  // Status changes every few seconds, so the connection panel subscribes
  // instead of polling. The listener is wrapped rather than passed through so
  // the renderer never receives Electron's event object.
  onTailnetStatus: (listener: (status: unknown) => void) => {
    const forward = (_event: unknown, status: unknown) => listener(status);
    ipcRenderer.on("tailnet:statusChanged", forward);
    return () => ipcRenderer.off("tailnet:statusChanged", forward);
  },
});
