package main

import (
	"crypto/sha256"
	"fmt"
	"io"

	"golang.org/x/crypto/hkdf"
)

var (
	// wrapSalt keeps KEK envelope unwrap compatible with existing replycant clients.
	wrapSalt = []byte("replycant-age-wrap-salt")
	// wrapInfo keeps KEK envelope unwrap compatible with existing replycant clients.
	wrapInfo = []byte("replycant-age-wrap-info")
)

// deriveWrapKey keeps test helpers compatible with historical package-private crypto utilities.
func deriveWrapKey(sharedSecret []byte) ([]byte, error) {
	reader := hkdf.New(sha256.New, sharedSecret, wrapSalt, wrapInfo)
	key := make([]byte, 32)
	if _, err := io.ReadFull(reader, key); err != nil {
		return nil, fmt.Errorf("failed to derive wrap key: %w", err)
	}
	return key, nil
}
