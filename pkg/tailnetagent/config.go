package tailnetagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// PersistedConfig is what survives a restart so later git commands can bring
// the node back without another pairing.
//
// No tailnet key is stored. The agent mints a single-use one with the device
// certificate whenever headscale does not know the node.
type PersistedConfig struct {
	HeadscaleAddr       string `json:"headscale_addr"`
	HeadscaleServerName string `json:"headscale_server_name"`
	Hostname            string `json:"hostname"`
}

// StartConfig is everything the agent needs, delivered on stdin so the device
// key never appears in the process list.
type StartConfig struct {
	GitDir              string `json:"git_dir"`
	HeadscaleAddr       string `json:"headscale_addr"`
	HeadscaleServerName string `json:"headscale_server_name"`
	CAPEM               string `json:"ca_pem"`
	ClientCertPEM       string `json:"client_cert_pem"`
	ClientKeyPEM        string `json:"client_key_pem"`
	Hostname            string `json:"hostname"`
}

// SaveConfig writes the join coordinates only after the node is actually up.
//
// A failed attempt therefore leaves nothing for the next command to trust,
// which matches the desktop app persisting tailnet config after join.
func SaveConfig(gitDir string, cfg PersistedConfig) error {
	if err := cfg.validate(); err != nil {
		return err
	}
	dir := Dir(gitDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create tailnet directory: %w", err)
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("encode tailnet configuration: %w", err)
	}
	path := configPath(dir)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return fmt.Errorf("write tailnet configuration: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish tailnet configuration: %w", err)
	}
	return nil
}

// LoadConfig reads the coordinates written after a successful join.
func LoadConfig(gitDir string) (PersistedConfig, error) {
	raw, err := os.ReadFile(configPath(Dir(gitDir)))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return PersistedConfig{}, ErrNotConfigured
		}
		return PersistedConfig{}, fmt.Errorf("read tailnet configuration: %w", err)
	}
	var cfg PersistedConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return PersistedConfig{}, fmt.Errorf("decode tailnet configuration: %w", err)
	}
	if err := cfg.validate(); err != nil {
		return PersistedConfig{}, err
	}
	return cfg, nil
}

func (c PersistedConfig) validate() error {
	missing := make([]string, 0, 3)
	if strings.TrimSpace(c.HeadscaleAddr) == "" {
		missing = append(missing, "headscale_addr")
	}
	if strings.TrimSpace(c.HeadscaleServerName) == "" {
		missing = append(missing, "headscale_server_name")
	}
	if strings.TrimSpace(c.Hostname) == "" {
		missing = append(missing, "hostname")
	}
	if len(missing) > 0 {
		return fmt.Errorf("tailnet configuration is missing %s", strings.Join(missing, ", "))
	}
	return nil
}

// LoadStartConfig rebuilds an agent stdin payload from files already stored
// in the repository.
func LoadStartConfig(gitDir string) (StartConfig, error) {
	persisted, err := LoadConfig(gitDir)
	if err != nil {
		return StartConfig{}, err
	}
	replycantDir := filepath.Join(gitDir, replycantDirName)
	caPEM, err := os.ReadFile(filepath.Join(replycantDir, "ca.pem"))
	if err != nil {
		return StartConfig{}, fmt.Errorf("read repository CA: %w", err)
	}
	certPEM, err := os.ReadFile(filepath.Join(replycantDir, "client-cert.pem"))
	if err != nil {
		return StartConfig{}, fmt.Errorf("read device certificate: %w", err)
	}
	keyPEM, err := os.ReadFile(filepath.Join(replycantDir, "client-key.pem"))
	if err != nil {
		return StartConfig{}, fmt.Errorf("read device key: %w", err)
	}
	return StartConfig{
		GitDir:              gitDir,
		HeadscaleAddr:       persisted.HeadscaleAddr,
		HeadscaleServerName: persisted.HeadscaleServerName,
		CAPEM:               string(caPEM),
		ClientCertPEM:       string(certPEM),
		ClientKeyPEM:        string(keyPEM),
		Hostname:            persisted.Hostname,
	}, nil
}

func encodeStartConfig(cfg StartConfig) ([]byte, error) {
	if strings.TrimSpace(cfg.GitDir) == "" {
		return nil, errors.New("tailnet agent configuration is missing git_dir")
	}
	if !filepath.IsAbs(cfg.GitDir) {
		return nil, fmt.Errorf("git_dir must be an absolute path, got %q", cfg.GitDir)
	}
	persisted := PersistedConfig{
		HeadscaleAddr:       cfg.HeadscaleAddr,
		HeadscaleServerName: cfg.HeadscaleServerName,
		Hostname:            cfg.Hostname,
	}
	if err := persisted.validate(); err != nil {
		return nil, err
	}
	for _, field := range []struct{ name, value string }{
		{"ca_pem", cfg.CAPEM},
		{"client_cert_pem", cfg.ClientCertPEM},
		{"client_key_pem", cfg.ClientKeyPEM},
	} {
		if strings.TrimSpace(field.value) == "" {
			return nil, fmt.Errorf("tailnet agent configuration is missing %s", field.name)
		}
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, fmt.Errorf("encode tailnet agent configuration: %w", err)
	}
	return raw, nil
}

// DecodeStartConfig parses the stdin payload the agent process receives.
func DecodeStartConfig(raw []byte) (StartConfig, error) {
	var cfg StartConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return StartConfig{}, fmt.Errorf("tailnet agent configuration is not valid JSON: %w", err)
	}
	if _, err := encodeStartConfig(cfg); err != nil {
		return StartConfig{}, err
	}
	return cfg, nil
}
