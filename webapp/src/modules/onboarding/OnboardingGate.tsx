import { ReactNode } from "react";
import { QRCodeSVG } from "qrcode.react";
import { WindowControls } from "../../components/WindowControls";
import { buildPublicKeyQrPayload, SyncSnapshot } from "../gitdb";
import { OnboardingFlowState } from "./useOnboardingFlow";

// Defines onboarding gate inputs so setup UI can be reused while App stays focused on composition.
interface OnboardingGateProps {
  flow: OnboardingFlowState;
  snapshot: SyncSnapshot;
  children: ReactNode;
}

// Renders setup screens until identity and initial sync bootstrap are ready for the main app shell.
export const OnboardingGate = ({ flow, snapshot, children }: OnboardingGateProps) => {
  if (flow.setupMode === "ready") {
    return <>{children}</>;
  }

  if (flow.setupMode === "checking") {
    return (
      <div className="setup-shell">
        <div className="setup-titlebar"><WindowControls /></div>
        <p>Checking local setup...</p>
      </div>
    );
  }

  if (flow.setupMode === "serverUrl") {
    return (
      <div className="setup-shell">
        <div className="setup-titlebar"><WindowControls /></div>
        <form
          className="setup-card"
          noValidate
          onSubmit={(event) => {
            event.preventDefault();
            void flow.handleDiscoverServer();
          }}
        >
          <h1>Replycant setup</h1>
          <p>
            Welcome to Replycant! Enter the URL to your Replycant server to get started.
          </p>
          <label>
            Server URL
            <input
              type="url"
              value={flow.serverUrlInput}
              onChange={(event) => flow.setServerUrlInput(event.target.value)}
              placeholder="http://replycant.local:8080"
              disabled={flow.isDiscovering}
            />
          </label>
          {flow.setupError ? <p className="setup-error">{flow.setupError}</p> : null}
          <button type="submit" disabled={flow.isDiscovering}>
            {flow.isDiscovering
              ? <span className="button-spinner" />
              : "Continue"}
          </button>
        </form>
      </div>
    );
  }

  if (flow.setupMode === "create") {
    return (
      <div className="setup-shell">
        <div className="setup-titlebar"><WindowControls /></div>
        <form
          className="setup-card"
          noValidate
          onSubmit={(event) => {
            event.preventDefault();
            void flow.handleCreateIdentity();
          }}
        >
          <h1>Replycant setup</h1>
          <p>
            Set a name for this device. The name will be tied to the encryption key created for this device.
          </p>
          <label>
            Device name
            <input
              type="text"
              value={flow.deviceNameInput}
              onChange={(event) => flow.setDeviceNameInput(event.target.value)}
              placeholder="replycant-webapp"
            />
          </label>
          {flow.passwordRequired ? (
            <label>
              Password
              <input
                type="password"
                value={flow.passwordInput}
                onChange={(event) => flow.setPasswordInput(event.target.value)}
                placeholder="Required to encrypt identity at rest"
                autoComplete="new-password"
              />
            </label>
          ) : null}
          {flow.setupError ? <p className="setup-error">{flow.setupError}</p> : null}
          <button type="submit">Generate keypair</button>
          <button type="button" className="setup-secondary-action" onClick={flow.handleStartOver}>
            Start over
          </button>
        </form>
      </div>
    );
  }

  if (flow.setupMode === "unlock") {
    return (
      <div className="setup-shell">
        <div className="setup-titlebar"><WindowControls /></div>
        <form
          className="setup-card"
          noValidate
          onSubmit={(event) => {
            event.preventDefault();
            void flow.handleUnlockIdentity();
          }}
        >
          <h1>Unlock Replycant</h1>
          <p>Enter your password to decrypt the local identity key.</p>
          <label>
            Password
            <input
              type="password"
              value={flow.passwordInput}
              onChange={(event) => flow.setPasswordInput(event.target.value)}
            />
          </label>
          {flow.setupError ? <p className="setup-error">{flow.setupError}</p> : null}
          <button type="submit">Unlock</button>
          <button type="button" className="setup-secondary-action" onClick={flow.handleStartOver}>
            Start over
          </button>
        </form>
      </div>
    );
  }

  if (flow.setupMode === "qr") {
    const qrPayload = flow.identityRecord && flow.caHash
      ? buildPublicKeyQrPayload({
          publicKeySsh: flow.identityRecord.publicKeySsh,
          agePublicKey: flow.identityRecord.agePublicKey,
          deviceName: flow.identityRecord.deviceName,
          deviceUUID: flow.identityRecord.deviceUUID,
        }, flow.caHash)
      : JSON.stringify({ pubkey: "", age_pubkey: "", name: "", uuid: "", ca_hash: "" });
    return (
      <div className="setup-shell">
        <div className="setup-titlebar"><WindowControls /></div>
        <div className="setup-card">
          <h1>Authorize this device</h1>
          <p>
            Scan this QR code from your iOS Replycant app by going to settings and selecting "Link a new device".
          </p>
          <div className="qr-code-container" style={{ textAlign: "center" }}>
            <QRCodeSVG value={qrPayload} size={256} />
          </div>
          {flow.setupError ? <p className="setup-error">{flow.setupError}</p> : null}
          <button type="button" className="setup-secondary-action" onClick={flow.handleStartOver}>
            Start over
          </button>
        </div>
      </div>
    );
  }

  const progress = snapshot.cloneProgress;
  const pct = progress ? Math.round(progress.progress * 100) : null;
  return (
    <div className="setup-shell">
      <div className="setup-titlebar"><WindowControls /></div>
      <div className="setup-card rehydration-card">
        <h1>Setting up your library</h1>
        <p className="rehydration-phase">{progress?.phase ?? "Preparing..."}</p>
        <p className="rehydration-detail">
        {progress?.loaded != null ? (
          <>
            {progress.loaded.toLocaleString()}
            {progress.total != null ? `/${progress.total.toLocaleString()}` : ""}
          </>
        ) : null}
        </p>
        <div className="rehydration-progress-track">
          <div
            className="rehydration-progress-fill"
            style={{ width: `${pct ?? 0}%` }}
          />
        </div>
        <p className="rehydration-count">{pct ?? 0}%</p>
        {flow.setupError ? (
          <>
            <p className="setup-error">{flow.setupError}</p>
            <button type="button" onClick={flow.retryRehydration}>
              Retry
            </button>
          </>
        ) : null}
        <button type="button" className="setup-secondary-action" onClick={flow.handleStartOver}>
          Start over
        </button>
      </div>
    </div>
  );
};
