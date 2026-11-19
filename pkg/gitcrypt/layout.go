package gitcrypt

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	// EncryptionSpacesPrefix is the folder that holds every space.
	// The space name is the next path segment, and it is the only
	// record of which space a file belongs to.
	EncryptionSpacesPrefix = "encryptionspaces/"
	// GlobalKeySetRoot holds the library KEK. A space without its own
	// encryption folder uses this key set.
	GlobalKeySetRoot = "encryption"
	// RecipientsFileName lists who a key set is wrapped for.
	RecipientsFileName = "recipients.yaml"
)

// recipientNameRE matches a KeySet metadata.name. A recipient that is
// not a key set name cannot be wrapped.
var recipientNameRE = regexp.MustCompile(`^[a-z][a-z0-9-]{0,252}$`)

// SpaceFromPath returns the space a repository path lives in.
// Paths outside encryptionspaces/ are not in a space.
func SpaceFromPath(filePath string) (string, bool) {
	if !strings.HasPrefix(filePath, EncryptionSpacesPrefix) {
		return "", false
	}
	rest := strings.TrimPrefix(filePath, EncryptionSpacesPrefix)
	space, _, ok := strings.Cut(rest, "/")
	if !ok || space == "" {
		return "", false
	}
	return space, true
}

// IsManifestPath reports a manifest inside a space. Key material that
// sits beside the manifests is not a manifest.
func IsManifestPath(filePath string) bool {
	return hasSpaceKind(filePath, "manifests")
}

// IsBinaryPath reports an LFS pointer inside a space.
func IsBinaryPath(filePath string) bool {
	return hasSpaceKind(filePath, "binary")
}

func hasSpaceKind(filePath, kind string) bool {
	space, ok := SpaceFromPath(filePath)
	if !ok {
		return false
	}
	return strings.HasPrefix(filePath, EncryptionSpacesPrefix+space+"/"+kind+"/")
}

// SpaceKeySetRoot is where a space keeps its own epochs.
func SpaceKeySetRoot(space string) string {
	return EncryptionSpacesPrefix + space + "/encryption"
}

// KeySetRoot is the directory whose epochs decrypt this file.
// spaceHasOwnKeySet reports whether that space contains
// encryption/current. Files outside a space use the global key set.
func KeySetRoot(filePath string, spaceHasOwnKeySet func(space string) bool) string {
	space, ok := SpaceFromPath(filePath)
	if !ok || spaceHasOwnKeySet == nil || !spaceHasOwnKeySet(space) {
		return GlobalKeySetRoot
	}
	return SpaceKeySetRoot(space)
}

// RecipientList is recipients.yaml. The global file names the library.
// A space file names only the extra key holders limited to that space,
// and may be empty.
type RecipientList struct {
	Members []string `yaml:"members,omitempty"`
}

// ParseRecipientList refuses a file that does not say exactly who is
// listed. An unknown field would change who can decrypt.
func ParseRecipientList(raw []byte) (RecipientList, error) {
	var list RecipientList
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	dec.KnownFields(true)
	if err := dec.Decode(&list); err != nil {
		return RecipientList{}, fmt.Errorf("parse recipients: %w", err)
	}
	if err := validateRecipientNames(list.Members); err != nil {
		return RecipientList{}, err
	}
	return list, nil
}

// MarshalRecipientList writes the file clients and gitd agree on.
func MarshalRecipientList(list RecipientList) ([]byte, error) {
	if err := validateRecipientNames(list.Members); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(list); err != nil {
		return nil, fmt.Errorf("encode recipients: %w", err)
	}
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("encode recipients: %w", err)
	}
	return buf.Bytes(), nil
}

// ResolveRecipients returns the age-recipient names for one key set.
// global names the library. extra names a space's own members and is
// nil when the space uses the global key set. Every name must be a
// known key set, and the library list must not be empty.
func ResolveRecipients(global, extra []string, known map[string]struct{}) ([]string, error) {
	if len(global) == 0 {
		return nil, fmt.Errorf("library has no members")
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(global)+len(extra))
	for _, name := range append(append([]string{}, global...), extra...) {
		if _, ok := known[name]; !ok {
			return nil, fmt.Errorf("unknown recipient %s", name)
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		out = append(out, name)
	}
	return out, nil
}

func validateRecipientNames(names []string) error {
	seen := map[string]struct{}{}
	for _, name := range names {
		if !recipientNameRE.MatchString(name) {
			return fmt.Errorf("invalid recipient name %q", name)
		}
		if _, ok := seen[name]; ok {
			return fmt.Errorf("duplicate recipient %s", name)
		}
		seen[name] = struct{}{}
	}
	return nil
}

// BuildFirstSpaceEpoch creates epoch 1 of a new space. The caller does
// not need an existing KEK: the space key is new, wrapped for agePubs,
// which are bech32 age public keys of every library member plus the
// space's own members. memberNames is only the space's extra members.
func BuildFirstSpaceEpoch(memberNames []string, agePubs []string) ([]byte, map[string][]byte, error) {
	if len(agePubs) == 0 {
		return nil, nil, fmt.Errorf("at least one recipient is required")
	}
	rawPubs := make([][]byte, 0, len(agePubs))
	for _, pub := range agePubs {
		raw, err := DecodeAgePublicKey(pub)
		if err != nil {
			return nil, nil, fmt.Errorf("age public key: %w", err)
		}
		rawPubs = append(rawPubs, raw)
	}
	kek := make([]byte, 32)
	if _, err := rand.Read(kek); err != nil {
		return nil, nil, err
	}
	epoch, err := WrapKEKForAgeRecipients(kek, rawPubs)
	if err != nil {
		return nil, nil, err
	}
	recipients, err := MarshalRecipientList(RecipientList{Members: memberNames})
	if err != nil {
		return nil, nil, err
	}
	return kek, map[string][]byte{
		"current":          []byte("1\n"),
		"epochs/1.age":     epoch,
		RecipientsFileName: recipients,
	}, nil
}
