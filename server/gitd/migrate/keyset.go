package migrate

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/mr-andreas/replycant/pkg/keyset"
)

// productionSteps is the ordered list gitd runs at boot. A later
// format appends one step and bumps DatabaseFormatVersion; the runner
// applies every step between the stored marker and that pin.
var productionSteps = []Step{
	{From: 1, Apply: keySetsFromPubkeyFiles},
}

// keySetsFromPubkeyFiles turns loose pubkeys/*.pub and *.age files
// into one KeySet each. The server never holds the KEK, so the
// display name is left unset and each device fills in its own later.
// An unpaired or unreadable key aborts the boot: skipping it would
// revoke that device.
func keySetsFromPubkeyFiles(tree *Tree) error {
	groups := map[string]*keyGroup{}
	for _, filePath := range tree.List("pubkeys/") {
		base := strings.TrimPrefix(filePath, "pubkeys/")
		if strings.Contains(base, "/") {
			return fmt.Errorf("unexpected file %s", filePath)
		}
		name, typ, kind, err := classifyPubkey(base)
		if err != nil {
			return fmt.Errorf("unexpected file %s", filePath)
		}
		data, err := tree.Read(filePath)
		if err != nil {
			return err
		}
		group := groups[name]
		if group == nil {
			group = &keyGroup{name: name, typ: typ}
			groups[name] = group
		}
		if err := group.add(filePath, typ, kind, bytes.TrimRight(data, "\r\n")); err != nil {
			return err
		}
	}

	for _, group := range groups {
		if group.pubPath == "" {
			return fmt.Errorf("orphan key file %s", group.agePath)
		}
		if group.agePath == "" {
			return fmt.Errorf("orphan key file %s", group.pubPath)
		}
		body, err := keyset.Marshal(keyset.KeySet{
			APIVersion: keyset.APIVersion,
			Kind:       keyset.Kind,
			Metadata:   keyset.Metadata{Name: group.name},
			Spec: keyset.Spec{
				Type:          group.typ,
				MTLSPublicKey: string(group.pub),
				AgePublicKey:  string(group.age),
			},
		})
		if err != nil {
			return fmt.Errorf("%s: %w", group.pubPath, err)
		}
		if err := tree.Write(keyset.Path(group.name), body); err != nil {
			return err
		}
		tree.Delete(group.pubPath)
		tree.Delete(group.agePath)
	}
	return nil
}

type keyGroup struct {
	name    string
	typ     string
	pubPath string
	agePath string
	pub     []byte
	age     []byte
}

func (g *keyGroup) add(filePath, typ, kind string, data []byte) error {
	if g.typ != typ {
		return fmt.Errorf("conflicting key files for %s", g.name)
	}
	switch kind {
	case "pub":
		if g.pubPath != "" {
			return fmt.Errorf("duplicate public key %s", filePath)
		}
		g.pubPath = filePath
		g.pub = data
	case "age":
		if g.agePath != "" {
			return fmt.Errorf("duplicate age key %s", filePath)
		}
		g.agePath = filePath
		g.age = data
	default:
		return fmt.Errorf("unexpected file %s", filePath)
	}
	return nil
}

func classifyPubkey(base string) (name string, typ string, kind string, err error) {
	switch {
	case strings.HasSuffix(base, ".recovery.pub"):
		return strings.TrimSuffix(base, ".recovery.pub"), keyset.TypeRecovery, "pub", nil
	case strings.HasSuffix(base, ".recovery.age"):
		return strings.TrimSuffix(base, ".recovery.age"), keyset.TypeRecovery, "age", nil
	case strings.HasSuffix(base, ".pub"):
		return strings.TrimSuffix(base, ".pub"), keyset.TypeDevice, "pub", nil
	case strings.HasSuffix(base, ".age"):
		return strings.TrimSuffix(base, ".age"), keyset.TypeDevice, "age", nil
	default:
		return "", "", "", fmt.Errorf("unclassified")
	}
}
