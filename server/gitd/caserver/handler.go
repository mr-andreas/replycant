package caserver

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/mr-andreas/replycant/server/gitd/qrgen"
)

//go:embed logo.png
var logoPNG []byte

// Mints a one-time tailnet join credential for a first-device CA page visit.
//
// A preauth key is single-use, so this runs on every request rather than
// once at startup. A failure must surface as 503, not a QR from an earlier
// successful mint.
type MintFunc func() (headscaleURL, preauthKey string, err error)

// Reports whether the repository has had its first push. Asked before every
// mint, because the page may be published on the LAN and must stop handing
// out join keys the moment the first-device window closes.
type BootstrappedFunc func() (bool, error)

// Configures the CA distribution page.
//
// LAN-only deployments (no Mint) serve {ca, url} so integration tests and
// host-port gitd keep working. Tailnet deployments mint a join credential
// instead: there is no reachable gitd URL until the device is on the tailnet.
// With Bootstrapped set, a tailnet page answers 410 Gone once the repository
// has a branch, since later devices pair through an existing device.
type Config struct {
	CA           string
	ServerURL    string
	Mint         MintFunc
	Bootstrapped BootstrappedFunc
}

// Distinguishes "the window has closed" from a transient failure, so visitors
// get a permanent answer rather than a retry prompt.
var errBootstrapped = errors.New("repository is already bootstrapped")

// Provides HTTP endpoints for distributing CA certificate and server URL via QR code.
// Enables mobile clients to scan and configure trust, while CLI clients can copy text directly.
type handler struct {
	ca           string
	serverURL    string
	mint         MintFunc
	bootstrapped BootstrappedFunc
	logoBase64   string
}

// Encodes CA and upstream URLs into a stable JSON shape for non-QR setup clients.
type lanConfig struct {
	CA  string `json:"ca"`
	URL string `json:"url"`
}

// First-device join on a tailnet: the CA to trust, where to register, and a
// single-use credential. No gitd URL — clients already know that address.
type tailnetConfig struct {
	CA           string `json:"ca"`
	HeadscaleURL string `json:"headscale_url"`
	PreauthKey   string `json:"preauth_key"`
}

// Creates an HTTP handler serving CA certificate distribution endpoints.
func NewHandler(cfg Config) (http.Handler, error) {
	h := &handler{
		ca:           cfg.CA,
		serverURL:    cfg.ServerURL,
		mint:         cfg.Mint,
		bootstrapped: cfg.Bootstrapped,
		logoBase64:   base64.StdEncoding.EncodeToString(logoPNG),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", h.handleIndex)
	mux.HandleFunc("/qr.png", h.handleQRCode)
	mux.HandleFunc("/config.json", h.handleConfigJSON)

	return mux, nil
}

// Builds the QR/JSON payload. Returns errBootstrapped instead of minting once
// the repository has a branch, and fails closed if that cannot be determined.
func (h *handler) qrPayload() ([]byte, error) {
	var data any
	if h.mint != nil {
		if h.bootstrapped != nil {
			done, err := h.bootstrapped()
			if err != nil {
				return nil, err
			}
			if done {
				return nil, errBootstrapped
			}
		}
		headscaleURL, preauthKey, err := h.mint()
		if err != nil {
			return nil, err
		}
		data = tailnetConfig{
			CA:           h.ca,
			HeadscaleURL: headscaleURL,
			PreauthKey:   preauthKey,
		}
	} else {
		data = lanConfig{CA: h.ca, URL: h.serverURL}
	}
	return json.Marshal(data)
}

// Answers a request whose payload could not be built. A closed bootstrap
// window is 410 so clients stop retrying; anything else is 503 so a stale QR
// is never served in place of a fresh credential.
func writePayloadError(w http.ResponseWriter, err error) {
	if errors.Is(err, errBootstrapped) {
		http.Error(w, "This library is already set up. Pair new devices from an existing device.", http.StatusGone)
		return
	}
	http.Error(w, "Failed to mint a join credential", http.StatusServiceUnavailable)
}

func generateQRCode(payload []byte) ([]byte, error) {
	qrCode, err := qrgen.GeneratePNG(string(payload), 256)
	if err != nil {
		return nil, fmt.Errorf("failed to generate QR code: %w", err)
	}
	return qrCode, nil
}

// Serves the main HTML page with QR code and copiable certificate data.
func (h *handler) handleIndex(w http.ResponseWriter, r *http.Request) {
	payload, err := h.qrPayload()
	if err != nil {
		writePayloadError(w, err)
		return
	}
	qrCode, err := generateQRCode(payload)
	if err != nil {
		http.Error(w, "Failed to generate QR code", http.StatusInternalServerError)
		return
	}

	serverDetails := ""
	if h.mint == nil {
		serverDetails = fmt.Sprintf(`
    <details>
        <summary>Server URL</summary>
        <div class="details-body">
            <pre id="url">%s</pre>
            <button class="copy-btn" onclick="copyToClipboard('url')">
                Copy URL
            </button>
        </div>
    </details>`, h.serverURL)
	}

	html := fmt.Sprintf(`<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>gitd - CA Certificate</title>
    <style>
        body {
            font-family: system-ui, -apple-system, sans-serif;
            max-width: 800px;
            margin: 40px auto;
            padding: 20px;
            line-height: 1.6;
            color: #333;
        }
        .header {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 16px;
            margin-bottom: 32px;
        }
        .header img {
            width: 64px;
            height: 64px;
        }
        .header h1 {
            margin: 0;
            font-size: 1.6em;
        }
        .qr-container {
            text-align: center;
            margin: 30px 0;
        }
        .qr-container img {
            border: 1px solid #ddd;
            padding: 20px;
            background: white;
            border-radius: 8px;
        }
        details {
            background: #f5f5f5;
            border: 1px solid #ddd;
            border-radius: 6px;
            margin: 12px 0;
        }
        summary {
            padding: 14px 16px;
            cursor: pointer;
            font-weight: 600;
            font-size: 1.05em;
            color: #555;
            user-select: none;
        }
        summary:hover {
            color: #333;
        }
        .details-body {
            padding: 0 16px 16px;
        }
        pre {
            background: #fff;
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 12px;
            overflow-x: auto;
            white-space: pre-wrap;
            word-wrap: break-word;
            font-size: 0.9em;
            margin: 0;
        }
        .copy-btn {
            background: #007bff;
            color: white;
            border: none;
            padding: 8px 16px;
            border-radius: 4px;
            cursor: pointer;
            margin-top: 8px;
            font-size: 0.9em;
        }
        .copy-btn:hover {
            background: #0056b3;
        }
    </style>
</head>
<body>
    <div class="header">
        <img src="data:image/png;base64,%s" alt="Replycant" />
        <h1>Replycant gitd server</h1>
    </div>

    <div class="qr-container">
        <p>Scan the QR code from the app to bootstrap your library.</p>
        <img src="data:image/png;base64,%s" alt="QR Code" />
    </div>
%s
    <details>
        <summary>CA Certificate</summary>
        <div class="details-body">
            <pre id="ca">%s</pre>
            <button class="copy-btn" onclick="copyToClipboard('ca')">
                Copy Certificate
            </button>
        </div>
    </details>

    <script>
        function copyToClipboard(elementId) {
            const el = document.getElementById(elementId);
            navigator.clipboard.writeText(el.textContent).then(() => {
                const btn = event.target;
                const orig = btn.textContent;
                btn.textContent = 'Copied!';
                setTimeout(() => { btn.textContent = orig; }, 2000);
            }).catch(err => {
                alert('Failed to copy: ' + err);
            });
        }
    </script>
</body>
</html>`, h.logoBase64, base64.StdEncoding.EncodeToString(qrCode), serverDetails, h.ca)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(html))
}

// Serves the QR code as a PNG image.
func (h *handler) handleQRCode(w http.ResponseWriter, r *http.Request) {
	payload, err := h.qrPayload()
	if err != nil {
		writePayloadError(w, err)
		return
	}
	qrCode, err := generateQRCode(payload)
	if err != nil {
		http.Error(w, "Failed to generate QR code", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Write(qrCode)
}

// Serves setup configuration JSON for clients that discover the server
// rather than scan its QR. Deliberately same-origin only: on a tailnet
// deployment the payload carries a live join key, and the page listens on the
// whole LAN, so any website the operator visited could otherwise read one.
// The desktop app fetches it from its own local server, which CORS does not
// govern.
func (h *handler) handleConfigJSON(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	payload, err := h.qrPayload()
	if err != nil {
		writePayloadError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(payload)
	w.Write([]byte("\n"))
}
