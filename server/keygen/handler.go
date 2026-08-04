package keygen

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/mr-andreas/replycant/server/gitd/qrgen"
)

// Serves a device-linking QR page so operators can onboard a new key using the iOS scanner flow.
type Handler struct {
	name         string
	uuid         string
	publicKey    string
	qrCodePNG    []byte
	qrCodeBase64 string
}

// Creates a QR handler that encodes device public key payload expected by DeviceLinkingView.
func NewHandler(name, uuid, publicKey string) (http.Handler, error) {
	qrCode, err := generateDeviceLinkQRCode(name, uuid, publicKey)
	if err != nil {
		return nil, err
	}

	h := &Handler{
		name:         name,
		uuid:         uuid,
		publicKey:    publicKey,
		qrCodePNG:    qrCode,
		qrCodeBase64: base64.StdEncoding.EncodeToString(qrCode),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", h.handleIndex)
	mux.HandleFunc("/qr.png", h.handleQRCode)
	return mux, nil
}

// Produces QR image bytes that carry the exact JSON schema consumed by iOS device linking.
func generateDeviceLinkQRCode(name, uuid, publicKey string) ([]byte, error) {
	payload := map[string]string{
		"pubkey": publicKey,
		"name":   name,
		"uuid":   uuid,
	}

	jsonPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal device link payload: %w", err)
	}

	qrCode, err := qrgen.GeneratePNG(string(jsonPayload), 256)
	if err != nil {
		return nil, fmt.Errorf("failed to generate QR code: %w", err)
	}

	return qrCode, nil
}

// Renders a minimal web page to make QR scanning and manual key copy equally easy during setup.
func (h *Handler) handleIndex(w http.ResponseWriter, _ *http.Request) {
	html := fmt.Sprintf(`<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>replycant keygen</title>
    <style>
        body {
            font-family: system-ui, -apple-system, sans-serif;
            max-width: 760px;
            margin: 40px auto;
            padding: 20px;
            line-height: 1.5;
        }
        h1 {
            color: #222;
        }
        .qr-container {
            text-align: center;
            margin: 24px 0;
        }
        .qr-container img {
            border: 1px solid #ddd;
            padding: 18px;
            background: #fff;
        }
        .info-box {
            background: #f5f5f5;
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 14px;
            margin: 16px 0;
        }
        .info-box h2 {
            margin-top: 0;
            font-size: 1.05em;
            color: #444;
        }
        pre {
            background: #fff;
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 10px;
            overflow-x: auto;
            white-space: pre-wrap;
            word-wrap: break-word;
            font-size: 0.9em;
        }
        .copy-btn {
            background: #007bff;
            color: white;
            border: none;
            padding: 8px 14px;
            border-radius: 4px;
            cursor: pointer;
            margin-top: 8px;
        }
        .copy-btn:hover {
            background: #005ec4;
        }
    </style>
</head>
<body>
    <h1>replycant device key</h1>
    <p>Scan this QR code with an already configured iOS device in <strong>Link New Device</strong>.</p>

    <div class="qr-container">
        <img src="data:image/png;base64,%s" alt="Device key QR code" />
    </div>

    <div class="info-box">
        <h2>Device Name</h2>
        <pre id="name">%s</pre>
        <button class="copy-btn" onclick="copyToClipboard('name')">Copy Name</button>
    </div>

    <div class="info-box">
        <h2>Device UUID</h2>
        <pre id="uuid">%s</pre>
        <button class="copy-btn" onclick="copyToClipboard('uuid')">Copy UUID</button>
    </div>

    <div class="info-box">
        <h2>Public Key</h2>
        <pre id="pubkey">%s</pre>
        <button class="copy-btn" onclick="copyToClipboard('pubkey')">Copy Public Key</button>
    </div>

    <script>
        function copyToClipboard(elementId) {
            const element = document.getElementById(elementId);
            const text = element.textContent;
            navigator.clipboard.writeText(text).then(() => {
                const btn = event.target;
                const originalText = btn.textContent;
                btn.textContent = 'Copied!';
                setTimeout(() => {
                    btn.textContent = originalText;
                }, 1200);
            }).catch(err => {
                alert('Failed to copy: ' + err);
            });
        }
    </script>
</body>
</html>`, h.qrCodeBase64, h.name, h.uuid, h.publicKey)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(html))
}

// Exposes the QR PNG directly for tools that want image-only integration.
func (h *Handler) handleQRCode(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(h.qrCodePNG)
}
