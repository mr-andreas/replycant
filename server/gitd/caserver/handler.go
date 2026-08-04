package caserver

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/mr-andreas/replycant/server/gitd/qrgen"
)

//go:embed logo.png
var logoPNG []byte

// Provides HTTP endpoints for distributing CA certificate and server URL via QR code.
// Enables mobile clients to scan and configure trust, while CLI clients can copy text directly.
type handler struct {
	ca            string
	serverURL     string
	qrCodePNG     []byte
	qrCodeBase64  string
	logoBase64    string
}

// Encodes CA and upstream URLs into a stable JSON shape for non-QR setup clients.
type configResponse struct {
	CA  string `json:"ca"`
	URL string `json:"url"`
}

// Creates an HTTP handler serving CA certificate distribution endpoints.
// The ca parameter is the PEM-encoded certificate content, serverURL is the gitd server address.
// Returns an error if QR code generation fails, ensuring the handler is ready to serve immediately.
func NewHandler(ca, serverURL string) (http.Handler, error) {
	qrCode, err := generateQRCode(ca, serverURL)
	if err != nil {
		return nil, err
	}

	h := &handler{
		ca:           ca,
		serverURL:    serverURL,
		qrCodePNG:    qrCode,
		qrCodeBase64: base64.StdEncoding.EncodeToString(qrCode),
		logoBase64:   base64.StdEncoding.EncodeToString(logoPNG),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", h.handleIndex)
	mux.HandleFunc("/qr.png", h.handleQRCode)
	mux.HandleFunc("/config.json", h.handleConfigJSON)

	return mux, nil
}

// Generates QR code containing CA certificate and server URL as JSON.
// The QR code encodes data that clients can parse to extract both values.
func generateQRCode(ca, serverURL string) ([]byte, error) {
	data := map[string]string{
		"ca":  ca,
		"url": serverURL,
	}

	jsonData, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal QR data: %w", err)
	}

	qrCode, err := qrgen.GeneratePNG(string(jsonData), 256)
	if err != nil {
		return nil, fmt.Errorf("failed to generate QR code: %w", err)
	}

	return qrCode, nil
}

// Serves the main HTML page with QR code and copiable certificate data.
// Provides both visual (QR) and textual interfaces for certificate distribution.
func (h *handler) handleIndex(w http.ResponseWriter, r *http.Request) {
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

    <details>
        <summary>Server URL</summary>
        <div class="details-body">
            <pre id="url">%s</pre>
            <button class="copy-btn" onclick="copyToClipboard('url')">
                Copy URL
            </button>
        </div>
    </details>

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
</html>`, h.logoBase64, h.qrCodeBase64, h.serverURL, h.ca)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(html))
}

// Serves the QR code as a PNG image.
// Allows direct image access for apps that prefer separate endpoints.
func (h *handler) handleQRCode(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "image/png")
	w.Write(h.qrCodePNG)
}

// Serves setup configuration JSON so browser onboarding can discover CA and upstream endpoints.
func (h *handler) handleConfigJSON(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	payload := configResponse{
		CA:  h.ca,
		URL: h.serverURL,
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		http.Error(w, "Failed to encode config JSON", http.StatusInternalServerError)
	}
}
