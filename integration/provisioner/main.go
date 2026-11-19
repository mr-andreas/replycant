package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/keyset"
)

type provisionerConfig struct {
	seederIdentityDir string
	newIdentityJSON   string
	bareRepo          string
	qrURL             string
	pairingSecret     string
	caFile            string
	headscaleURL      string
	pairURL           string
}

func runGit(dir string, args ...string) error {
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git %v failed: %w: %s", args, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func readIdentity(path string) (gitcrypt.Identity, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return gitcrypt.Identity{}, err
	}
	var identity gitcrypt.Identity
	if err := json.Unmarshal(raw, &identity); err != nil {
		return gitcrypt.Identity{}, err
	}
	return identity, nil
}

func addGlobalMember(workDir, name string) error {
	path := filepath.Join(workDir, gitcrypt.GlobalKeySetRoot, gitcrypt.RecipientsFileName)
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read recipients: %w", err)
	}
	list, err := gitcrypt.ParseRecipientList(raw)
	if err != nil {
		return err
	}
	for _, member := range list.Members {
		if member == name {
			return nil
		}
	}
	list.Members = append(list.Members, name)
	body, err := gitcrypt.MarshalRecipientList(list)
	if err != nil {
		return err
	}
	return os.WriteFile(path, body, 0o644)
}

func rewrapEveryEpoch(workDir, agePrivate string, recipients [][]byte) error {
	roots := []string{filepath.Join(workDir, "encryption", "epochs")}
	spaces, _ := filepath.Glob(filepath.Join(workDir, "encryptionspaces", "*", "encryption", "epochs"))
	roots = append(roots, spaces...)
	for _, root := range roots {
		matches, err := filepath.Glob(filepath.Join(root, "*.age"))
		if err != nil {
			return err
		}
		for _, path := range matches {
			raw, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(raw, agePrivate)
			if err != nil {
				return fmt.Errorf("unwrap %s: %w", path, err)
			}
			wrapped, err := gitcrypt.WrapKEKForAgeRecipients(kek, recipients)
			if err != nil {
				return err
			}
			if err := os.WriteFile(path, wrapped, 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func collectRecipients(workDir string, newIdentity gitcrypt.Identity) ([][]byte, error) {
	paths, err := filepath.Glob(filepath.Join(workDir, "pubkeys", "*.yaml"))
	if err != nil {
		return nil, err
	}

	unique := map[string]struct{}{}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		parsed, err := keyset.Parse(raw)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
		key := strings.TrimSpace(parsed.Spec.AgePublicKey)
		if key == "" {
			continue
		}
		unique[key] = struct{}{}
	}
	unique[strings.TrimSpace(newIdentity.AgePublicKey)] = struct{}{}

	recipients := make([][]byte, 0, len(unique))
	for key := range unique {
		if key == "" {
			continue
		}
		rawPub, err := gitcrypt.DecodeAgePublicKey(key)
		if err != nil {
			return nil, fmt.Errorf("decode recipient %q: %w", key, err)
		}
		recipients = append(recipients, rawPub)
	}
	if len(recipients) == 0 {
		return nil, fmt.Errorf("no recipients found")
	}
	return recipients, nil
}

// resolvePairing decides whether this run also approves a tailnet pairing.
// The CLI suite scrapes the clone's loopback QR page; host-side suites only
// have the secret, and the age key is then the new identity's own. It runs
// before anything is committed so a missing payload leaves the repo alone.
func resolvePairing(ctx context.Context, cfg provisionerConfig, newAgePublicKey string) (qrPayload, bool, error) {
	switch {
	case cfg.qrURL != "" && cfg.pairingSecret != "":
		return qrPayload{}, false, fmt.Errorf("--qr-url and --pairing-secret are mutually exclusive")
	case cfg.qrURL != "":
		payload, err := fetchQRPayload(ctx, cfg.qrURL)
		return payload, err == nil, err
	case cfg.pairingSecret != "":
		return qrPayload{
			PairingSecret: strings.TrimSpace(cfg.pairingSecret),
			AgePublicKey:  strings.TrimSpace(newAgePublicKey),
		}, true, nil
	default:
		return qrPayload{}, false, nil
	}
}

func provision(cfg provisionerConfig) error {
	seederIdentity, err := readIdentity(filepath.Join(cfg.seederIdentityDir, "identity.json"))
	if err != nil {
		return fmt.Errorf("read seeder identity: %w", err)
	}
	newIdentity, err := readIdentity(cfg.newIdentityJSON)
	if err != nil {
		return fmt.Errorf("read new identity: %w", err)
	}
	payload, pairing, err := resolvePairing(context.Background(), cfg, newIdentity.AgePublicKey)
	if err != nil {
		return err
	}

	workDir, err := os.MkdirTemp("", "replycant-provisioner-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(workDir)

	if err := runGit("", "clone", "file://"+cfg.bareRepo, workDir); err != nil {
		return err
	}
	if err := runGit(workDir, "checkout", "main"); err != nil {
		return err
	}
	if err := gitcrypt.RequireSupportedDatabaseVersionInWorktree(workDir); err != nil {
		return err
	}

	currentRaw, err := os.ReadFile(filepath.Join(workDir, "encryption", "current"))
	if err != nil {
		return fmt.Errorf("read encryption/current: %w", err)
	}
	epoch, err := gitcrypt.ParseCurrentEpoch(currentRaw)
	if err != nil {
		return fmt.Errorf("parse current epoch: %w", err)
	}
	epochPath := filepath.Join(workDir, "encryption", "epochs", fmt.Sprintf("%d.age", epoch))
	epochEnvelope, err := os.ReadFile(epochPath)
	if err != nil {
		return fmt.Errorf("read epoch envelope: %w", err)
	}
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(epochEnvelope, seederIdentity.AgePrivateKeyBase64)
	if err != nil {
		return fmt.Errorf("unwrap kek: %w", err)
	}

	recipients, err := collectRecipients(workDir, newIdentity)
	if err != nil {
		return err
	}

	name := strings.TrimSpace(newIdentity.DeviceName)
	uuid := strings.TrimSpace(newIdentity.DeviceUUID)
	if name == "" || uuid == "" {
		return fmt.Errorf("new identity missing device name or uuid")
	}
	base := name + "-" + uuid
	display, err := keyset.EncryptDisplayName(kek, epoch, base, name)
	if err != nil {
		return fmt.Errorf("encrypt display name: %w", err)
	}
	body, err := keyset.Marshal(keyset.KeySet{
		APIVersion: keyset.APIVersion,
		Kind:       keyset.Kind,
		Metadata:   keyset.Metadata{Name: base},
		Spec: keyset.Spec{
			Type:          keyset.TypeDevice,
			MTLSPublicKey: strings.TrimSpace(newIdentity.PublicKeySSH),
			AgePublicKey:  strings.TrimSpace(newIdentity.AgePublicKey),
			DisplayName:   &display,
		},
	})
	if err != nil {
		return fmt.Errorf("marshal key set: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(workDir, "pubkeys"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(workDir, keyset.Path(base)), body, 0o644); err != nil {
		return err
	}
	if err := addGlobalMember(workDir, base); err != nil {
		return err
	}
	if err := rewrapEveryEpoch(workDir, seederIdentity.AgePrivateKeyBase64, recipients); err != nil {
		return err
	}

	addArgs := []string{"add", "pubkeys", "encryption"}
	if _, statErr := os.Stat(filepath.Join(workDir, "encryptionspaces")); statErr == nil {
		addArgs = append(addArgs, "encryptionspaces")
	}
	if err := runGit(workDir, addArgs...); err != nil {
		return err
	}
	if err := runGit(workDir, "-c", "user.name=integration", "-c", "user.email=integration@replycant.local", "commit", "-m", "authorize new device"); err != nil {
		return err
	}
	if err := runGit(workDir, "push", "origin", "main"); err != nil {
		return err
	}
	if !pairing {
		return nil
	}
	if cfg.caFile == "" || cfg.headscaleURL == "" || cfg.pairURL == "" {
		return fmt.Errorf("--ca-file, --headscale-url, and --pair-url are required to approve a pairing")
	}
	caPEM, err := os.ReadFile(cfg.caFile)
	if err != nil {
		return fmt.Errorf("read deployment CA: %w", err)
	}
	// The new key is on main before this join, so hsproxy will accept the
	// pairing device once gitd publishes the record and that device connects.
	return approveTailnetPairing(context.Background(), cfg.seederIdentityDir, string(caPEM), cfg.headscaleURL, cfg.pairURL, payload)
}

func main() {
	cfg := provisionerConfig{}
	flag.StringVar(&cfg.seederIdentityDir, "seeder-identity-dir", "", "Directory containing seeder identity.json")
	flag.StringVar(&cfg.newIdentityJSON, "new-identity-json", "", "Path to new device identity.json")
	flag.StringVar(&cfg.bareRepo, "bare-repo", "", "Path to bare repository")
	flag.StringVar(&cfg.qrURL, "qr-url", "", "Clone QR payload URL; set to approve a tailnet pairing")
	flag.StringVar(&cfg.pairingSecret, "pairing-secret", "", "Pairing secret from the new device's QR; approves a tailnet pairing for --new-identity-json")
	flag.StringVar(&cfg.caFile, "ca-file", "", "Deployment CA PEM the seeder pins for hsproxy")
	flag.StringVar(&cfg.headscaleURL, "headscale-url", "", "hsproxy URL the seeder mints its tailnet key from")
	flag.StringVar(&cfg.pairURL, "pair-url", "", "gitd /pair URL inside the tailnet")
	flag.Parse()

	if cfg.seederIdentityDir == "" || cfg.newIdentityJSON == "" || cfg.bareRepo == "" {
		fmt.Fprintln(os.Stderr, "--seeder-identity-dir, --new-identity-json, and --bare-repo are required")
		os.Exit(1)
	}

	if err := provision(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "provisioner failed: %v\n", err)
		os.Exit(1)
	}
}
