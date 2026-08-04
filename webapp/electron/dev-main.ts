import { app, BrowserWindow, ipcMain, Menu, nativeTheme, safeStorage, shell } from "electron";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { URL } from "node:url";
import { registerIdentityKeyIpc } from "./registerIdentityKeyIpc";

const APP_NAME = "Replycant";

let mainWindow: BrowserWindow | null = null;

// Builds the renderer URL for local development where Vite hosts UI and proxies API routes.
const resolveDevUrl = (): string => {
  const raw = process.env.ELECTRON_RENDERER_URL ?? "http://127.0.0.1:5173";
  return new URL(raw).toString();
};

// Creates the development desktop shell while preserving renderer hardening defaults.
const createMainWindow = async (): Promise<void> => {
  // Linux compositors handle window transparency inconsistently, which leaves
  // the frosted-glass treatment looking like rendering garbage instead of the
  // intended effect. Fall back to an opaque window there so the UI stays solid.
  const isLinux = process.platform === "linux";
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    frame: false,
    transparent: !isLinux,
    backgroundColor: isLinux ? "#ffffff" : "#00000000",
    // Keep the macOS vibrancy material lit even when the window loses focus;
    // the default "followWindow" state collapses the blur into a flat fill,
    // which reads as an opaque background instead of the intended frosted glass.
    ...(process.platform === "darwin"
      ? { vibrancy: "sidebar" as const, visualEffectState: "active" as const }
      : {}),
    ...(process.platform === "win32" ? { backgroundMaterial: "acrylic" as const } : {}),
    webPreferences: {
      preload: resolve(import.meta.dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  await mainWindow.loadURL(resolveDevUrl());
  mainWindow.webContents.on("before-input-event", (event, input) => {
    if (input.type !== "keyDown") {
      return;
    }

    const isMacToggle =
      process.platform === "darwin" &&
      input.meta &&
      input.alt &&
      input.key.toLowerCase() === "i";
    const isLinuxOrWindowsToggle =
      process.platform !== "darwin" &&
      ((input.control && input.shift && input.key.toLowerCase() === "i") || input.key === "F12");

    if (!isMacToggle && !isLinuxOrWindowsToggle) {
      return;
    }

    event.preventDefault();
    mainWindow?.webContents.toggleDevTools();
  });
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
};

// Routes signal-driven shutdown through Electron's quit lifecycle.
const handleShutdownSignal = (): void => {
  app.quit();
};
process.on("SIGINT", handleShutdownSignal);
process.on("SIGTERM", handleShutdownSignal);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    await createMainWindow();
  }
});

app.whenReady().then(async () => {
  app.setName(APP_NAME);
  Menu.setApplicationMenu(null);
  nativeTheme.themeSource = "light";

  // Persists desktop page-state in app-owned files rather than Chromium's
  // storage area so navigation restores reliably across shutdown paths.
  const storeDir = join(app.getPath("userData"), "replycant");
  mkdirSync(storeDir, { recursive: true });
  registerIdentityKeyIpc(ipcMain, { safeStorage, storeDir });
  const lastPagePath = join(storeDir, "lastPage.json");
  ipcMain.on("lastPage:read", (event) => {
    try {
      event.returnValue = existsSync(lastPagePath)
        ? JSON.parse(readFileSync(lastPagePath, "utf-8"))
        : null;
    } catch {
      event.returnValue = null;
    }
  });
  ipcMain.on("lastPage:write", (event, state: unknown) => {
    try {
      const tempPath = `${lastPagePath}.tmp`;
      writeFileSync(tempPath, JSON.stringify(state), "utf-8");
      renameSync(tempPath, lastPagePath);
      event.returnValue = true;
    } catch {
      event.returnValue = false;
    }
  });

  ipcMain.handle("window:minimize", () => {
    BrowserWindow.getFocusedWindow()?.minimize();
  });
  ipcMain.handle("window:maximize", () => {
    const win = BrowserWindow.getFocusedWindow();
    if (win?.isMaximized()) {
      win.unmaximize();
    } else {
      win?.maximize();
    }
  });
  ipcMain.handle("window:close", () => {
    BrowserWindow.getFocusedWindow()?.close();
  });

  await createMainWindow();
});
