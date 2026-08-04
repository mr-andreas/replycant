package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"gopkg.in/yaml.v3"
)

// seederConfig holds seeding inputs for one bare repository.
type seederConfig struct {
	bareRepo     string
	outputDir    string
	deviceSpace  string
	mediaCount   int
	commitCount  int
	addMediaOnly bool
}

// mustRunGit executes one git command and fails fast with stderr output.
func mustRunGit(dir string, args ...string) {
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Fprintf(os.Stderr, "git %v failed: %s\n", args, string(out))
		os.Exit(1)
	}
}

// writeFile ensures directories exist before writing fixture files.
func writeFile(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, content, mode)
}

const apiVersion = "media.replycant.com/v1alpha1"

// originalManifest keeps seeded fixtures aligned with
// replycant-importer/webapp manifest decoding.
type originalManifest struct {
	APIVersion string                 `yaml:"apiVersion"`
	Kind       string                 `yaml:"kind"`
	Metadata   map[string]string      `yaml:"metadata"`
	Spec       map[string]interface{} `yaml:"spec"`
	Status     map[string]interface{} `yaml:"status"`
}

// thumbnailSetManifest keeps timeline thumbnail lookups deterministic in integration tests.
type thumbnailSetManifest struct {
	APIVersion string                 `yaml:"apiVersion"`
	Kind       string                 `yaml:"kind"`
	Metadata   map[string]string      `yaml:"metadata"`
	Spec       map[string]interface{} `yaml:"spec"`
	Status     map[string]interface{} `yaml:"status"`
}

// seedRepository supports full initialization and append-only media seeding for integration tests.
func seedRepository(cfg seederConfig) error {
	if cfg.addMediaOnly {
		return appendMediaOnly(cfg)
	}
	return initializeRepository(cfg)
}

// initializeRepository creates the initial auth/encryption commit and optional media batch commits.
func initializeRepository(cfg seederConfig) error {
	identity, keyPEM, certPEM, err := gitcrypt.CreateIdentityWithMTLS("integration-device")
	if err != nil {
		return fmt.Errorf("create identity: %w", err)
	}
	recipientPub, err := gitcrypt.DecodeAgePublicKey(identity.AgePublicKey)
	if err != nil {
		return fmt.Errorf("decode age recipient: %w", err)
	}
	kek := make([]byte, 32)
	if _, err := rand.Read(kek); err != nil {
		return fmt.Errorf("generate kek: %w", err)
	}
	envelope, err := gitcrypt.WrapKEKForAge(kek, recipientPub)
	if err != nil {
		return fmt.Errorf("wrap kek for age: %w", err)
	}
	manifestPlaintext := []byte("apiVersion: media.replycant.com/v1alpha1\nkind: Original\nmetadata:\n  seeded: true\n")
	manifestEncrypted, err := gitcrypt.EncryptManifestEnvelope(manifestPlaintext, kek, 1)
	if err != nil {
		return fmt.Errorf("encrypt manifest: %w", err)
	}
	if err := os.MkdirAll(cfg.outputDir, 0o755); err != nil {
		return fmt.Errorf("create output dir: %w", err)
	}
	identityPath := filepath.Join(cfg.outputDir, "identity.json")
	identityJSON, err := json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal identity json: %w", err)
	}
	if err := os.WriteFile(identityPath, append(identityJSON, '\n'), 0o600); err != nil {
		return fmt.Errorf("write identity json: %w", err)
	}
	if err := os.WriteFile(filepath.Join(cfg.outputDir, "client-key.pem"), keyPEM, 0o600); err != nil {
		return fmt.Errorf("write client key: %w", err)
	}
	if err := os.WriteFile(filepath.Join(cfg.outputDir, "client-cert.pem"), certPEM, 0o600); err != nil {
		return fmt.Errorf("write client cert: %w", err)
	}

	workDir, err := os.MkdirTemp("", "replycant-seeder-*")
	if err != nil {
		return fmt.Errorf("create temp workdir: %w", err)
	}
	defer os.RemoveAll(workDir)

	mustRunGit("", "init", "--initial-branch=main", workDir)
	if err := writeFile(filepath.Join(workDir, "pubkeys", "integration-device.pub"), []byte(identity.PublicKeySSH+"\n"), 0o644); err != nil {
		return fmt.Errorf("write pubkey: %w", err)
	}
	if err := writeFile(filepath.Join(workDir, "pubkeys", "integration-device.age"), []byte(identity.AgePublicKey+"\n"), 0o644); err != nil {
		return fmt.Errorf("write age pubkey: %w", err)
	}
	if err := writeFile(filepath.Join(workDir, "encryption", "current"), []byte("1\n"), 0o644); err != nil {
		return fmt.Errorf("write current epoch: %w", err)
	}
	if err := writeFile(filepath.Join(workDir, "encryption", "epochs", "1.age"), envelope, 0o644); err != nil {
		return fmt.Errorf("write wrapped kek: %w", err)
	}
	if err := writeFile(filepath.Join(workDir, "manifests", "test", "test.yaml"), manifestEncrypted, 0o644); err != nil {
		return fmt.Errorf("write manifest: %w", err)
	}
	mustRunGit(workDir, "add", ".")
	mustRunGit(workDir, "-c", "user.name=integration", "-c", "user.email=integration@replycant.local", "commit", "-m", "seed integration repo")
	mustRunGit(workDir, "remote", "add", "origin", "file://"+cfg.bareRepo)
	if err := appendMediaCommits(workDir, kek, 1, cfg); err != nil {
		return err
	}
	mustRunGit(workDir, "push", "-u", "origin", "main")
	return nil
}

// appendMediaOnly reuses the seeded identity and repository encryption state to add commit history.
func appendMediaOnly(cfg seederConfig) error {
	identityPath := filepath.Join(cfg.outputDir, "identity.json")
	rawIdentity, err := os.ReadFile(identityPath)
	if err != nil {
		return fmt.Errorf("read identity json: %w", err)
	}
	var identity gitcrypt.Identity
	if err := json.Unmarshal(rawIdentity, &identity); err != nil {
		return fmt.Errorf("parse identity json: %w", err)
	}
	workDir, err := os.MkdirTemp("", "replycant-seeder-*")
	if err != nil {
		return fmt.Errorf("create temp workdir: %w", err)
	}
	defer os.RemoveAll(workDir)
	mustRunGit("", "clone", "file://"+cfg.bareRepo, workDir)
	mustRunGit(workDir, "checkout", "main")
	currentRaw, err := os.ReadFile(filepath.Join(workDir, "encryption", "current"))
	if err != nil {
		return fmt.Errorf("read encryption/current: %w", err)
	}
	epoch, err := gitcrypt.ParseCurrentEpoch(currentRaw)
	if err != nil {
		return fmt.Errorf("parse current epoch: %w", err)
	}
	envelopePath := filepath.Join(workDir, "encryption", "epochs", fmt.Sprintf("%d.age", epoch))
	envelope, err := os.ReadFile(envelopePath)
	if err != nil {
		return fmt.Errorf("read epoch envelope: %w", err)
	}
	kek, err := gitcrypt.UnwrapKEKFromAgeEnvelope(envelope, identity.AgePrivateKeyBase64)
	if err != nil {
		return fmt.Errorf("unwrap kek: %w", err)
	}
	if err := appendMediaCommits(workDir, kek, epoch, cfg); err != nil {
		return err
	}
	mustRunGit(workDir, "pull", "--rebase", "origin", "main")
	mustRunGit(workDir, "push", "origin", "main")
	return nil
}

// appendMediaCommits creates deterministic media manifests distributed across multiple commits.
func appendMediaCommits(workDir string, kek []byte, epoch int, cfg seederConfig) error {
	if cfg.mediaCount == 0 {
		return nil
	}
	for commitIdx := 0; commitIdx < cfg.commitCount; commitIdx += 1 {
		start, end := mediaRangeForCommit(cfg.mediaCount, cfg.commitCount, commitIdx)
		for mediaIdx := start; mediaIdx < end; mediaIdx += 1 {
			if err := writeMediaManifestPair(workDir, kek, epoch, cfg.deviceSpace, mediaIdx); err != nil {
				return err
			}
		}
		mustRunGit(workDir, "add", ".")
		mustRunGit(
			workDir,
			"-c",
			"user.name=integration",
			"-c",
			"user.email=integration@replycant.local",
			"commit",
			"-m",
			fmt.Sprintf("seed media batch %d/%d", commitIdx+1, cfg.commitCount),
		)
	}
	return nil
}

// writeMediaManifestPair writes encrypted Original and ThumbnailSet manifests for one media index.
func writeMediaManifestPair(workDir string, kek []byte, epoch int, deviceSpace string, mediaIdx int) error {
	name := fmt.Sprintf("img-%06d", mediaIdx)
	day := time.Date(2024, 1, 1, 12, 0, 0, 0, time.UTC).AddDate(0, 0, mediaIdx).Format(time.RFC3339)
	original := originalManifest{
		APIVersion: apiVersion,
		Kind:       "Original",
		Metadata: map[string]string{
			"name":        name,
			"deviceSpace": deviceSpace,
		},
		Spec: map[string]interface{}{
			"id":         fmt.Sprintf("id-%s", name),
			"sha256":     fmt.Sprintf("%064x", mediaIdx+1),
			"path":       fmt.Sprintf("/camera/%s.jpg", name),
			"filesize":   1024,
			"mediaType":  "image",
			"width":      1200,
			"height":     800,
			"isFavorite": false,
			"isHidden":   false,
			"createdAt":  day,
			"takenAt":    day,
			"mimeType":   "image/jpeg",
		},
		Status: map[string]interface{}{},
	}
	thumbnail := thumbnailSetManifest{
		APIVersion: apiVersion,
		Kind:       "ThumbnailSet",
		Metadata: map[string]string{
			"name":        "thumbs-" + name,
			"deviceSpace": deviceSpace,
		},
		Spec: map[string]interface{}{
			"originalRef": fmt.Sprintf("%s/%s/Original/%s", deviceSpace, apiVersion, name),
			"thumbnails": []map[string]interface{}{
				{
					"name":     fmt.Sprintf("thumb-%s.jpg", name),
					"sha256":   fmt.Sprintf("%064x", mediaIdx+1_000_001),
					"width":    280,
					"height":   280,
					"filesize": 512,
				},
			},
		},
		Status: map[string]interface{}{},
	}
	if err := writeEncryptedManifest(workDir, kek, epoch, manifestPath(deviceSpace, "Original", name), original); err != nil {
		return err
	}
	if err := writeEncryptedManifest(workDir, kek, epoch, manifestPath(deviceSpace, "ThumbnailSet", "thumbs-"+name), thumbnail); err != nil {
		return err
	}
	return nil
}

// writeEncryptedManifest serializes protocol YAML and stores it as an encrypted envelope blob.
func writeEncryptedManifest(workDir string, kek []byte, epoch int, path string, manifest interface{}) error {
	plaintext, err := yaml.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("marshal manifest yaml: %w", err)
	}
	encrypted, err := gitcrypt.EncryptManifestEnvelope(plaintext, kek, epoch)
	if err != nil {
		return fmt.Errorf("encrypt manifest envelope: %w", err)
	}
	if err := writeFile(filepath.Join(workDir, path), encrypted, 0o644); err != nil {
		return fmt.Errorf("write encrypted manifest: %w", err)
	}
	return nil
}

// manifestPath keeps test fixtures aligned with the production manifest tree layout.
func manifestPath(deviceSpace string, kind string, name string) string {
	return filepath.Join("manifests", deviceSpace, "media.replycant.com", "v1alpha1", kind, shardName(name)+".yaml")
}

// shardName mirrors replycant-importer and webapp sharding to avoid path
// fanout regressions in tests.
func shardName(name string) string {
	if len(name) < 5 {
		return name
	}
	return filepath.Join(name[:2], name[2:4], name[4:])
}

// mediaRangeForCommit spreads media across commits with stable ordering and balanced batch sizes.
func mediaRangeForCommit(total int, commitCount int, commitIdx int) (int, int) {
	base := total / commitCount
	remainder := total % commitCount
	start := commitIdx*base + min(commitIdx, remainder)
	count := base
	if commitIdx < remainder {
		count += 1
	}
	return start, start + count
}

func min(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

// validateConfig catches invalid combinations early so test failures are explicit.
func validateConfig(cfg seederConfig) error {
	if strings.TrimSpace(cfg.bareRepo) == "" {
		return fmt.Errorf("--bare-repo is required")
	}
	if strings.TrimSpace(cfg.outputDir) == "" {
		return fmt.Errorf("--output-dir is required")
	}
	if strings.TrimSpace(cfg.deviceSpace) == "" {
		return fmt.Errorf("--device-space is required")
	}
	if cfg.mediaCount < 0 {
		return fmt.Errorf("--media-count must be >= 0")
	}
	if cfg.commitCount < 1 {
		return fmt.Errorf("--commit-count must be >= 1")
	}
	if cfg.mediaCount > 0 && cfg.commitCount > cfg.mediaCount {
		return fmt.Errorf("--commit-count cannot exceed --media-count when media is requested")
	}
	return nil
}

func main() {
	cfg := seederConfig{}
	flag.StringVar(&cfg.bareRepo, "bare-repo", "", "Path to bare repository to seed")
	flag.StringVar(&cfg.outputDir, "output-dir", "", "Directory where identity files are written")
	flag.StringVar(&cfg.deviceSpace, "device-space", "e2e-device", "Device space used for seeded media manifests")
	flag.IntVar(&cfg.mediaCount, "media-count", 0, "Number of media records to seed")
	flag.IntVar(&cfg.commitCount, "commit-count", 1, "Number of commits to distribute seeded media across")
	flag.BoolVar(&cfg.addMediaOnly, "add-media-only", false, "Only append media commits to an existing seeded repository")
	flag.Parse()
	if err := validateConfig(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	if err := seedRepository(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "seeder failed: %v\n", err)
		os.Exit(1)
	}
}
