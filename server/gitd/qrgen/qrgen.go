package qrgen

import (
	"github.com/skip2/go-qrcode"
)

// Generates a QR code as PNG image data for the given content string.
// Enables mobile clients to quickly scan and import CA certificates and server URLs.
func GeneratePNG(data string, size int) ([]byte, error) {
	return qrcode.Encode(data, qrcode.Medium, size)
}

