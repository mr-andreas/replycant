// Package keyset is the plaintext record of who may open a library.
//
// gitd and hsproxy have to read the mTLS key before any device has
// unwrapped the KEK, so the file stays outside manifests/ and is not
// encrypted. The display name is the exception: it is sealed with the
// KEK so the server cannot read "Andreas's iPhone".
package keyset

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"gopkg.in/yaml.v3"
)

const (
	// APIVersion is the schema clients and gitd agree on for this file.
	APIVersion = "gitdb.replycant.com/v1alpha1"
	// Kind is the manifest kind stored in pubkeys/, not under manifests/.
	Kind = "KeySet"
	// TypeDevice is a phone or computer that holds its own private keys.
	TypeDevice = "device"
	// TypeRecovery is a backup credential, not a device shown in Settings.
	TypeRecovery = "recovery"
	// TypeApp is another client, such as an upload app. The value is a
	// display label only: it never decides what that client can decrypt.
	TypeApp = "app"
	// displayNameAADPrefix binds a sealed name to one key set so a
	// server that rewrites plaintext YAML cannot move the name.
	displayNameAADPrefix = "replycant-keyset-display-name-v1"
)

// ErrDisplayNameAbsent reports that this key set has no sealed name.
// Callers show metadata.name instead of treating that as corruption.
var ErrDisplayNameAbsent = errors.New("key set has no display name")

var namePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,252}$`)

// KeySet is one key holder's mTLS key and age key, stored together so
// they cannot drift apart the way the old .pub and .age files could.
type KeySet struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   Metadata `yaml:"metadata"`
	Spec       Spec     `yaml:"spec"`
}

// Metadata names the key set. Name is the file stem and the slug users
// see when the display name cannot be decrypted.
type Metadata struct {
	Name string `yaml:"name"`
}

// Spec holds the public material gitd authorizes and clients wrap the
// KEK to. DisplayName is optional because a server migration cannot
// encrypt one.
type Spec struct {
	Type          string       `yaml:"type"`
	MTLSPublicKey string       `yaml:"mtlsPublicKey"`
	AgePublicKey  string       `yaml:"agePublicKey"`
	DisplayName   *DisplayName `yaml:"displayName,omitempty"`
}

// DisplayName is the KEK-sealed label. Ciphertext is base64 of
// nonce || ciphertext || GCM tag.
type DisplayName struct {
	KekEpoch   int    `yaml:"kekEpoch"`
	Ciphertext string `yaml:"ciphertext"`
}

// Parse rejects a file that cannot be used to authorize someone, so a
// truncated write does not become a member of the library.
func Parse(raw []byte) (KeySet, error) {
	var ks KeySet
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	dec.KnownFields(true)
	if err := dec.Decode(&ks); err != nil {
		return KeySet{}, fmt.Errorf("parse key set: %w", err)
	}
	if err := validate(ks); err != nil {
		return KeySet{}, err
	}
	return ks, nil
}

// Marshal writes the canonical file body. It refuses a key set Parse
// would reject, so writers cannot publish a file gitd will skip.
func Marshal(ks KeySet) ([]byte, error) {
	if err := validate(ks); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(ks); err != nil {
		return nil, fmt.Errorf("encode key set: %w", err)
	}
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("encode key set: %w", err)
	}
	return buf.Bytes(), nil
}

// Path is where this key set lives. The stem must equal metadata.name
// so a renamed file cannot claim another holder's identity.
func Path(name string) string {
	return "pubkeys/" + name + ".yaml"
}

// EncryptDisplayName seals a label to one key set and one KEK epoch.
// The name argument is metadata.name, which becomes the AAD.
func EncryptDisplayName(kek []byte, epoch int, name string, plaintext string) (DisplayName, error) {
	if epoch < 1 {
		return DisplayName{}, fmt.Errorf("invalid kek epoch %d", epoch)
	}
	if strings.TrimSpace(plaintext) == "" {
		return DisplayName{}, errors.New("display name is empty")
	}
	if !namePattern.MatchString(name) {
		return DisplayName{}, fmt.Errorf("invalid key set name %q", name)
	}
	combined, err := gitcrypt.EncryptAesGcmCombined(kek, []byte(plaintext), displayNameAAD(name))
	if err != nil {
		return DisplayName{}, fmt.Errorf("encrypt display name: %w", err)
	}
	return DisplayName{
		KekEpoch:   epoch,
		Ciphertext: base64.StdEncoding.EncodeToString(combined),
	}, nil
}

// DecryptDisplayName opens a sealed label. It fails when the file has
// no label, or when metadata.name is not the name the label was sealed to.
func DecryptDisplayName(kek []byte, ks KeySet) (string, error) {
	if ks.Spec.DisplayName == nil {
		return "", ErrDisplayNameAbsent
	}
	sealed := ks.Spec.DisplayName
	if sealed.KekEpoch < 1 {
		return "", fmt.Errorf("invalid kek epoch %d", sealed.KekEpoch)
	}
	combined, err := base64.StdEncoding.DecodeString(sealed.Ciphertext)
	if err != nil {
		return "", fmt.Errorf("decode display name: %w", err)
	}
	plain, err := gitcrypt.DecryptAesGcmCombined(kek, combined, displayNameAAD(ks.Metadata.Name))
	if err != nil {
		return "", fmt.Errorf("decrypt display name: %w", err)
	}
	return string(plain), nil
}

// ParseMTLSPublicKey reads the SSH line stored in spec.mtlsPublicKey.
// gitd compares the result with the client certificate.
func ParseMTLSPublicKey(content string) (*ecdsa.PublicKey, error) {
	content = strings.TrimSpace(content)
	parts := strings.Fields(content)
	if len(parts) < 2 {
		return nil, fmt.Errorf("invalid SSH public key format")
	}
	if parts[0] != "ecdsa-sha2-nistp256" {
		return nil, fmt.Errorf("not a P-256 key (type: %s)", parts[0])
	}
	decoded, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("failed to decode base64: %w", err)
	}
	offset := 0
	if len(decoded) < 4 {
		return nil, fmt.Errorf("decoded key too short")
	}
	keyTypeLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4
	if len(decoded) < offset+int(keyTypeLen) {
		return nil, fmt.Errorf("decoded key too short for key type")
	}
	keyType := string(decoded[offset : offset+int(keyTypeLen)])
	offset += int(keyTypeLen)
	if keyType != "ecdsa-sha2-nistp256" {
		return nil, fmt.Errorf("unexpected key type: %s", keyType)
	}
	if len(decoded) < offset+4 {
		return nil, fmt.Errorf("decoded key too short for curve length")
	}
	curveLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4
	if len(decoded) < offset+int(curveLen) {
		return nil, fmt.Errorf("decoded key too short for curve")
	}
	curveID := string(decoded[offset : offset+int(curveLen)])
	offset += int(curveLen)
	if curveID != "nistp256" {
		return nil, fmt.Errorf("unexpected curve: %s", curveID)
	}
	if len(decoded) < offset+4 {
		return nil, fmt.Errorf("decoded key too short for point length")
	}
	pointLen := binary.BigEndian.Uint32(decoded[offset:])
	offset += 4
	if len(decoded) < offset+int(pointLen) {
		return nil, fmt.Errorf("decoded key too short for point data")
	}
	pointData := decoded[offset : offset+int(pointLen)]
	if len(pointData) != 65 || pointData[0] != 0x04 {
		return nil, fmt.Errorf("invalid uncompressed point format")
	}
	curve := elliptic.P256()
	x, y := elliptic.Unmarshal(curve, pointData)
	if x == nil {
		return nil, fmt.Errorf("failed to unmarshal point")
	}
	return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
}

func displayNameAAD(name string) []byte {
	return append([]byte(displayNameAADPrefix), name...)
}

func validate(ks KeySet) error {
	if ks.APIVersion != APIVersion {
		return fmt.Errorf("unsupported key set apiVersion %q", ks.APIVersion)
	}
	if ks.Kind != Kind {
		return fmt.Errorf("unsupported key set kind %q", ks.Kind)
	}
	if !namePattern.MatchString(ks.Metadata.Name) {
		return fmt.Errorf("invalid key set name %q", ks.Metadata.Name)
	}
	switch ks.Spec.Type {
	case TypeDevice, TypeRecovery, TypeApp:
	default:
		return fmt.Errorf("unsupported key set type %q", ks.Spec.Type)
	}
	if _, err := ParseMTLSPublicKey(ks.Spec.MTLSPublicKey); err != nil {
		return fmt.Errorf("mtls public key: %w", err)
	}
	if _, err := gitcrypt.DecodeAgePublicKey(ks.Spec.AgePublicKey); err != nil {
		return fmt.Errorf("age public key: %w", err)
	}
	if ks.Spec.DisplayName == nil {
		return nil
	}
	if ks.Spec.DisplayName.KekEpoch < 1 {
		return fmt.Errorf("invalid display name kek epoch %d", ks.Spec.DisplayName.KekEpoch)
	}
	if _, err := base64.StdEncoding.DecodeString(ks.Spec.DisplayName.Ciphertext); err != nil {
		return fmt.Errorf("display name ciphertext: %w", err)
	}
	return nil
}
