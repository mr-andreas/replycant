import React from "react";
import ReactDOM from "react-dom/client";
import { Buffer } from "buffer";
import { App } from "./App";
import "./styles.css";

// Provides Buffer globally because isomorphic-git depends on it in browser mode.
if (!("Buffer" in globalThis)) {
  (globalThis as typeof globalThis & { Buffer: typeof Buffer }).Buffer = Buffer;
}

if (window.replycantDesktop) {
  document.documentElement.classList.add("desktop");
}

// Restores persisted hash before boot so startup paths read the saved anchors.
if (window.replycantDesktop && !window.location.hash) {
  const hash = window.replycantDesktop.persistedLastPage?.hash;
  if (hash) {
    window.location.hash = hash.startsWith("#") ? hash : `#${hash}`;
  }
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
