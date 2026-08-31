package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
)

type provisionerConfig struct {
	seederIdentityDir string
	newIdentityJSON   string
	bareRepo          string
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

func collectRecipients(workDir string, newIdentity gitcrypt.Identity) ([][]byte, error) {
	paths, err := filepath.Glob(filepath.Join(workDir, "pubkeys", "*.age"))
	if err != nil {
		return nil, err
	}

	unique := map[string]struct{}{}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		key := strings.TrimSpace(string(raw))
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

func provision(cfg provisionerConfig) error {
	seederIdentity, err := readIdentity(filepath.Join(cfg.seederIdentityDir, "identity.json"))
	if err != nil {
		return fmt.Errorf("read seeder identity: %w", err)
	}
	newIdentity, err := readIdentity(cfg.newIdentityJSON)
	if err != nil {
		return fmt.Errorf("read new identity: %w", err)
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
	rewrapped, err := gitcrypt.WrapKEKForAgeRecipients(kek, recipients)
	if err != nil {
		return fmt.Errorf("rewrap kek: %w", err)
	}

	name := strings.TrimSpace(newIdentity.DeviceName)
	uuid := strings.TrimSpace(newIdentity.DeviceUUID)
	if name == "" || uuid == "" {
		return fmt.Errorf("new identity missing device name or uuid")
	}
	base := name + "-" + uuid
	pubPath := filepath.Join(workDir, "pubkeys", base+".pub")
	agePath := filepath.Join(workDir, "pubkeys", base+".age")

	if err := os.WriteFile(pubPath, []byte(strings.TrimSpace(newIdentity.PublicKeySSH)+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(agePath, []byte(strings.TrimSpace(newIdentity.AgePublicKey)+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(epochPath, rewrapped, 0o644); err != nil {
		return err
	}

	if err := runGit(workDir, "add", "pubkeys", filepath.Join("encryption", "epochs", fmt.Sprintf("%d.age", epoch))); err != nil {
		return err
	}
	if err := runGit(workDir, "-c", "user.name=integration", "-c", "user.email=integration@replycant.local", "commit", "-m", "authorize new device"); err != nil {
		return err
	}
	if err := runGit(workDir, "push", "origin", "main"); err != nil {
		return err
	}
	return nil
}

func main() {
	cfg := provisionerConfig{}
	flag.StringVar(&cfg.seederIdentityDir, "seeder-identity-dir", "", "Directory containing seeder identity.json")
	flag.StringVar(&cfg.newIdentityJSON, "new-identity-json", "", "Path to new device identity.json")
	flag.StringVar(&cfg.bareRepo, "bare-repo", "", "Path to bare repository")
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
