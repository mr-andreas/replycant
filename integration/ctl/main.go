package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

const (
	// listenAddr keeps the control API reachable from host-side integration tests.
	listenAddr = ":18447"
	// repoPath points at the bare repository managed by integration entrypoint tooling.
	repoPath = "/tmp/repo.git"
	// seederIdentityDir stores the seeded identity used for provisioning additional devices.
	seederIdentityDir = "/tmp/identity"
)

// controlServer serializes mutating operations so reset/seed/provision never race on one repo.
type controlServer struct {
	mu sync.Mutex
}

// resetRequest captures caller intent for reseeding vs blank bootstrap repositories.
type resetRequest struct {
	Seed bool `json:"seed"`
}

// provisionRequest carries public onboarding material for one new device authorization.
type provisionRequest struct {
	DeviceName   string `json:"deviceName"`
	DeviceUUID   string `json:"deviceUUID"`
	PublicKeySSH string `json:"publicKeySSH"`
	AgePublicKey string `json:"agePublicKey"`
}

// seedRequest configures deterministic media-history fixtures for sync and rewind integration tests.
type seedRequest struct {
	MediaCount  int    `json:"mediaCount"`
	CommitCount int    `json:"commitCount"`
	DeviceSpace string `json:"deviceSpace"`
}

// controlResponse keeps API failures explicit so tests can fail with actionable diagnostics.
type controlResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// runCommand executes one binary and returns combined output for consistent error reporting.
func runCommand(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return strings.TrimSpace(string(out)), fmt.Errorf("%s %v failed: %w", name, args, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// writeJSON centralizes API responses so tests can parse status and message uniformly.
func writeJSON(w http.ResponseWriter, status int, payload controlResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

// decodeJSONRequest validates JSON payload shape early so test failures stay deterministic.
func decodeJSONRequest(r *http.Request, dst any) error {
	if !strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		return errors.New("content-type must be application/json")
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return fmt.Errorf("invalid json body: %w", err)
	}
	return nil
}

// resetRepository recreates the bare repo and optional seed state via shared container bootstrap logic.
func resetRepository(seed bool) error {
	seedArg := "false"
	if seed {
		seedArg = "true"
	}
	if _, err := runCommand("/usr/local/bin/reset-repo.sh", seedArg); err != nil {
		return fmt.Errorf("reset repo script: %w", err)
	}
	return nil
}

// handleHealthz confirms the control plane is accepting requests.
func (s *controlServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, controlResponse{OK: false, Error: "method not allowed"})
		return
	}
	writeJSON(w, http.StatusOK, controlResponse{OK: true})
}

// handleReset reinitializes repository state for bootstrap and provisioning scenarios.
func (s *controlServer) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, controlResponse{OK: false, Error: "method not allowed"})
		return
	}
	var req resetRequest
	if err := decodeJSONRequest(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, controlResponse{OK: false, Error: err.Error()})
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := resetRepository(req.Seed); err != nil {
		writeJSON(w, http.StatusInternalServerError, controlResponse{OK: false, Error: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, controlResponse{OK: true})
}

// handleProvision authorizes one externally generated device identity against the seeded repo.
func (s *controlServer) handleProvision(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, controlResponse{OK: false, Error: "method not allowed"})
		return
	}
	var req provisionRequest
	if err := decodeJSONRequest(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, controlResponse{OK: false, Error: err.Error()})
		return
	}
	if strings.TrimSpace(req.DeviceName) == "" || strings.TrimSpace(req.DeviceUUID) == "" ||
		strings.TrimSpace(req.PublicKeySSH) == "" || strings.TrimSpace(req.AgePublicKey) == "" {
		writeJSON(w, http.StatusBadRequest, controlResponse{OK: false, Error: "deviceName, deviceUUID, publicKeySSH, and agePublicKey are required"})
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, err := os.Stat(filepath.Join(seederIdentityDir, "identity.json")); err != nil {
		writeJSON(w, http.StatusConflict, controlResponse{OK: false, Error: "seed identity missing; reset with seed=true first"})
		return
	}

	tempPath := filepath.Join(os.TempDir(), "provision-request-"+req.DeviceUUID+".json")
	payload, err := json.Marshal(req)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, controlResponse{OK: false, Error: fmt.Sprintf("marshal request: %v", err)})
		return
	}
	if err := os.WriteFile(tempPath, append(payload, '\n'), 0o600); err != nil {
		writeJSON(w, http.StatusInternalServerError, controlResponse{OK: false, Error: fmt.Sprintf("write temp identity: %v", err)})
		return
	}
	defer os.Remove(tempPath)

	if _, err := runCommand(
		"provisioner",
		"--seeder-identity-dir="+seederIdentityDir,
		"--new-identity-json="+tempPath,
		"--bare-repo="+repoPath,
	); err != nil {
		writeJSON(w, http.StatusInternalServerError, controlResponse{OK: false, Error: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, controlResponse{OK: true})
}

// handleSeed appends deterministic media commits to the current seeded repository.
func (s *controlServer) handleSeed(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, controlResponse{OK: false, Error: "method not allowed"})
		return
	}
	var req seedRequest
	if err := decodeJSONRequest(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, controlResponse{OK: false, Error: err.Error()})
		return
	}
	if req.MediaCount < 0 {
		writeJSON(w, http.StatusBadRequest, controlResponse{OK: false, Error: "mediaCount must be >= 0"})
		return
	}
	if req.CommitCount < 1 {
		req.CommitCount = 1
	}
	deviceSpace := strings.TrimSpace(req.DeviceSpace)
	if deviceSpace == "" {
		deviceSpace = "e2e-device"
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, err := os.Stat(filepath.Join(seederIdentityDir, "identity.json")); err != nil {
		writeJSON(w, http.StatusConflict, controlResponse{OK: false, Error: "seed identity missing; reset with seed=true first"})
		return
	}

	_, err := runCommand(
		"seeder",
		"--add-media-only",
		"--bare-repo="+repoPath,
		"--output-dir="+seederIdentityDir,
		"--device-space="+deviceSpace,
		"--media-count="+strconv.Itoa(req.MediaCount),
		"--commit-count="+strconv.Itoa(req.CommitCount),
	)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, controlResponse{OK: false, Error: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, controlResponse{OK: true})
}

// main boots the control API used by iOS integration tests to manage repo lifecycle.
func main() {
	server := &controlServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", server.handleHealthz)
	mux.HandleFunc("/reset", server.handleReset)
	mux.HandleFunc("/provision", server.handleProvision)
	mux.HandleFunc("/seed", server.handleSeed)

	httpServer := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
	}
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintf(os.Stderr, "ctl server failed: %v\n", err)
		os.Exit(1)
	}
}
