//go:build integration

package integration

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	testImage = "replycant-integration:test"
)

// cleanupStaleContainers removes abandoned integration containers from prior interrupted runs.
func cleanupStaleContainers() {
	_ = exec.Command(
		"bash",
		"-c",
		"docker rm -f $(docker ps -q --filter label=replycant-integration=true) 2>/dev/null",
	).Run()
}

// TestMain builds the container image once for the integration suite.
func TestMain(m *testing.M) {
	if _, err := exec.LookPath("docker"); err != nil {
		fmt.Fprintln(os.Stderr, "docker is required for integration tests")
		os.Exit(1)
	}

	cleanupStaleContainers()

	build := exec.Command("docker", "build", "-f", "integration/Dockerfile", "-t", testImage, ".")
	build.Dir = ".."
	build.Stdout = os.Stdout
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to build integration image: %v\n", err)
		os.Exit(1)
	}

	os.Exit(m.Run())
}

// startContainer creates one ephemeral integration environment and waits for readiness.
func startContainer(t *testing.T) string {
	t.Helper()
	run := exec.Command(
		"docker",
		"run",
		"--rm",
		"-d",
		"--label",
		"replycant-integration=true",
		testImage,
	)
	out, err := run.CombinedOutput()
	require.NoErrorf(t, err, "docker run failed: %s", string(out))
	containerID := strings.TrimSpace(string(out))
	require.NotEmpty(t, containerID)

	t.Cleanup(func() {
		_ = exec.Command("docker", "rm", "-f", containerID).Run()
	})

	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		_, err := dockerExecAllowFail(containerID, "test", "-f", "/tmp/ready")
		if err == nil {
			return containerID
		}
		time.Sleep(1 * time.Second)
	}

	logs, _ := exec.Command("docker", "logs", containerID).CombinedOutput()
	t.Fatalf("container did not become ready in time\n%s", string(logs))
	return ""
}

// dockerExec runs one command in a container and fails the test on error.
func dockerExec(t *testing.T, containerID string, args ...string) string {
	t.Helper()
	out, err := dockerExecAllowFail(containerID, args...)
	require.NoErrorf(t, err, "docker exec %v failed: %s", args, out)
	return out
}

// dockerExecAllowFail runs one command in a container and returns output and error.
func dockerExecAllowFail(containerID string, args ...string) (string, error) {
	cmdArgs := append([]string{"exec", containerID}, args...)
	cmd := exec.Command("docker", cmdArgs...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// readFile returns one file's content from inside a test container.
func readFile(t *testing.T, containerID string, path string) string {
	t.Helper()
	return dockerExec(t, containerID, "cat", path)
}

// runReplycantClone executes the real git-replycant clone workflow against gitd.
func runReplycantClone(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	out, err := runReplycantCloneAllowFail(containerID, cloneDir)
	require.NoErrorf(t, err, "git-replycant clone failed: %s", out)
}

func runReplycantCloneAllowFail(containerID string, cloneDir string) (string, error) {
	return dockerExecAllowFail(
		containerID,
		"git-replycant",
		"clone",
		"http://localhost:8080",
		cloneDir,
	)
}

// runReplycantCloneBareAllowFail executes clone in bare mode without LFS setup.
func runReplycantCloneBareAllowFail(containerID string, cloneDir string) (string, error) {
	return dockerExecAllowFail(
		containerID,
		"git-replycant",
		"clone",
		"--bare",
		"--no-lfs",
		"http://localhost:8080",
		cloneDir,
	)
}

func waitForIdentity(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	identityPath := cloneDir + "/.git/replycant/identity.json"
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := dockerExecAllowFail(containerID, "test", "-f", identityPath); err == nil {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("identity file not created in time: %s", identityPath)
}

// waitForIdentityBare waits for the bare-repo identity path used when .git is the repository root.
func waitForIdentityBare(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	identityPath := cloneDir + "/replycant/identity.json"
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := dockerExecAllowFail(containerID, "test", "-f", identityPath); err == nil {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("identity file not created in time: %s", identityPath)
}

func provisionDevice(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	dockerExec(
		t,
		containerID,
		"provisioner",
		"--seeder-identity-dir=/tmp/identity",
		"--new-identity-json="+cloneDir+"/.git/replycant/identity.json",
		"--bare-repo=/tmp/repo.git",
	)
}

func cloneAndProvision(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	cloneErr := make(chan error, 1)
	go func() {
		out, err := runReplycantCloneAllowFail(containerID, cloneDir)
		if err != nil {
			cloneErr <- fmt.Errorf("%s: %w", out, err)
			return
		}
		cloneErr <- nil
	}()
	waitForIdentity(t, containerID, cloneDir)
	provisionDevice(t, containerID, cloneDir)
	select {
	case err := <-cloneErr:
		require.NoError(t, err)
	case <-time.After(120 * time.Second):
		t.Fatal("clone timed out")
	}
	dockerExec(t, containerID, "git", "-C", cloneDir, "pull", "--rebase", "origin", "main")
}

// cloneAndProvisionBare runs onboarding for bare clone mode where no working tree checkout is expected.
func cloneAndProvisionBare(t *testing.T, containerID string, cloneDir string) {
	t.Helper()
	cloneErr := make(chan error, 1)
	go func() {
		out, err := runReplycantCloneBareAllowFail(containerID, cloneDir)
		if err != nil {
			cloneErr <- fmt.Errorf("%s: %w", out, err)
			return
		}
		cloneErr <- nil
	}()
	waitForIdentityBare(t, containerID, cloneDir)
	dockerExec(
		t,
		containerID,
		"provisioner",
		"--seeder-identity-dir=/tmp/identity",
		"--new-identity-json="+cloneDir+"/replycant/identity.json",
		"--bare-repo=/tmp/repo.git",
	)
	select {
	case err := <-cloneErr:
		require.NoError(t, err)
	case <-time.After(120 * time.Second):
		t.Fatal("clone timed out")
	}
}

// sha256File computes deterministic checksums for binary round-trip assertions.
func sha256File(t *testing.T, containerID string, path string) string {
	t.Helper()
	out := dockerExec(t, containerID, "sha256sum", path)
	fields := strings.Fields(strings.TrimSpace(out))
	require.NotEmpty(t, fields)
	return fields[0]
}

// parsePointerOID extracts the sha256 object id from a Git LFS pointer blob.
func parsePointerOID(t *testing.T, blob string) string {
	t.Helper()
	lines := strings.Split(strings.ReplaceAll(blob, "\r\n", "\n"), "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "oid sha256:") {
			oid := strings.TrimSpace(strings.TrimPrefix(trimmed, "oid sha256:"))
			require.NotEmpty(t, oid)
			return oid
		}
	}
	t.Fatalf("lfs pointer missing oid line:\n%s", blob)
	return ""
}

// TestE2EManifestWorkflow validates clone, manifest encryption on push, and pull behavior.
func TestE2EManifestWorkflow(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	t.Run("clone", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/clone")

		out := readFile(t, containerID, "/tmp/clone/manifests/test/test.yaml")
		assert.Contains(t, out, "apiVersion:")
		assert.NotContains(t, out, "REPLYCANT-ENC-V1")
	})

	t.Run("modify_and_push", func(t *testing.T) {
		dockerExec(t, containerID, "sh", "-c", "printf 'apiVersion: v1\\nkind: Modified\\n' > /tmp/clone/manifests/test/test.yaml")
		dockerExec(t, containerID, "git", "-C", "/tmp/clone", "add", ".")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/clone",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"update manifest",
		)
		dockerExec(t, containerID, "git", "-C", "/tmp/clone", "push", "origin", "main")

		blob := dockerExec(t, containerID, "git", "-C", "/tmp/clone", "show", "HEAD:manifests/test/test.yaml")
		assert.Contains(t, blob, "REPLYCANT-ENC-V1")
	})

	t.Run("second_clone_sees_changes", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/clone-2")
		out := readFile(t, containerID, "/tmp/clone-2/manifests/test/test.yaml")
		assert.Contains(t, out, "kind: Modified")
	})

	t.Run("pull_gets_latest", func(t *testing.T) {
		dockerExec(t, containerID, "git", "-C", "/tmp/clone", "pull", "origin", "main")
		dockerExec(t, containerID, "sh", "-c", "printf 'apiVersion: v1\\nkind: Final\\n' > /tmp/clone/manifests/test/test.yaml")
		dockerExec(t, containerID, "git", "-C", "/tmp/clone", "add", ".")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/clone",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"final update",
		)
		dockerExec(t, containerID, "git", "-C", "/tmp/clone", "push", "origin", "main")
		dockerExec(t, containerID, "git", "-C", "/tmp/clone-2", "pull", "origin", "main")
		out := readFile(t, containerID, "/tmp/clone-2/manifests/test/test.yaml")
		assert.Contains(t, out, "kind: Final")
	})
}

// TestE2EBinaryWorkflow validates binary path encryption through LFS pointer + object round-trips.
func TestE2EBinaryWorkflow(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	var firstChecksum string
	var secondChecksum string

	t.Run("clone_and_add_binary", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/binary-clone")

		dockerExec(t, containerID, "mkdir", "-p", "/tmp/binary-clone/binary")
		dockerExec(t, containerID, "sh", "-c", "head -c 65536 /dev/urandom > /tmp/binary-clone/binary/test.bin")
		firstChecksum = sha256File(t, containerID, "/tmp/binary-clone/binary/test.bin")

		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "add", "binary/test.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/binary-clone",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"add binary",
		)
		blob := dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "show", "HEAD:binary/test.bin")
		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "push", "origin", "main")
		assert.Contains(t, blob, "version https://git-lfs.github.com/spec/v1")
		assert.Contains(t, blob, "x-replycant-kek-epoch")
		assert.Contains(t, blob, "x-replycant-wrapped-dek")
	})

	t.Run("second_clone_restores_plaintext", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/binary-clone-2")
		secondChecksum = sha256File(t, containerID, "/tmp/binary-clone-2/binary/test.bin")
		assert.Equal(t, firstChecksum, secondChecksum)
	})

	t.Run("fetch_and_checkout_updates_binary", func(t *testing.T) {
		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "pull", "origin", "main")
		dockerExec(t, containerID, "sh", "-c", "head -c 32768 /dev/urandom > /tmp/binary-clone/binary/test.bin")
		updatedChecksum := sha256File(t, containerID, "/tmp/binary-clone/binary/test.bin")
		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "add", "binary/test.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/binary-clone",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"update binary",
		)
		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone", "push", "origin", "main")

		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone-2", "fetch", "origin", "main")
		dockerExec(t, containerID, "git", "-C", "/tmp/binary-clone-2", "checkout", "origin/main", "--", "binary/test.bin")
		pulledChecksum := sha256File(t, containerID, "/tmp/binary-clone-2/binary/test.bin")
		assert.Equal(t, updatedChecksum, pulledChecksum)
	})
}

// TestE2ELFSModifyAndPull validates modify->push->pull behavior for LFS-encrypted binaries.
func TestE2ELFSModifyAndPull(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	var originalChecksum string
	var updatedChecksum string

	t.Run("initial_binary_push", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-mod")

		dockerExec(t, containerID, "mkdir", "-p", "/tmp/lfs-mod/binary")
		dockerExec(t, containerID, "sh", "-c", "head -c 65536 /dev/urandom > /tmp/lfs-mod/binary/data.bin")
		originalChecksum = sha256File(t, containerID, "/tmp/lfs-mod/binary/data.bin")

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod", "add", "binary/data.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/lfs-mod",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"add lfs binary",
		)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod", "push", "origin", "main")
	})

	t.Run("second_clone_sees_initial_binary", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-mod-2")
		clonedChecksum := sha256File(t, containerID, "/tmp/lfs-mod-2/binary/data.bin")
		assert.Equal(t, originalChecksum, clonedChecksum)
	})

	t.Run("modify_push_and_pull", func(t *testing.T) {
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod", "pull", "origin", "main")
		dockerExec(t, containerID, "sh", "-c", "head -c 32768 /dev/urandom > /tmp/lfs-mod/binary/data.bin")
		updatedChecksum = sha256File(t, containerID, "/tmp/lfs-mod/binary/data.bin")
		assert.NotEqual(t, originalChecksum, updatedChecksum)

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod", "add", "binary/data.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/lfs-mod",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"update lfs binary",
		)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod", "push", "origin", "main")

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-mod-2", "pull", "origin", "main")
		pulledChecksum := sha256File(t, containerID, "/tmp/lfs-mod-2/binary/data.bin")
		assert.Equal(t, updatedChecksum, pulledChecksum)
	})
}

// TestE2ELFSCrossCloneUpdate validates create->push in clone A, then modify->push in clone B, then pull in clone A.
func TestE2ELFSCrossCloneUpdate(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	var initialChecksum string
	var modifiedChecksum string

	t.Run("clone_a_create_binary_and_push", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-cross-a")

		dockerExec(t, containerID, "mkdir", "-p", "/tmp/lfs-cross-a/binary")
		dockerExec(t, containerID, "sh", "-c", "head -c 65536 /dev/urandom > /tmp/lfs-cross-a/binary/test.bin")
		initialChecksum = sha256File(t, containerID, "/tmp/lfs-cross-a/binary/test.bin")

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-a", "add", "binary/test.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/lfs-cross-a",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"add cross-clone binary",
		)
		blob := dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-a", "show", "HEAD:binary/test.bin")
		oid := parsePointerOID(t, blob)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-a", "lfs", "push", "--object-id", "origin", oid)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-a", "push", "origin", "main")
	})

	t.Run("clone_b_clone_verify_modify_and_push", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-cross-b")
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-b", "pull", "origin", "main")

		clonedChecksum := sha256File(t, containerID, "/tmp/lfs-cross-b/binary/test.bin")
		assert.Equal(t, initialChecksum, clonedChecksum)

		dockerExec(t, containerID, "sh", "-c", "head -c 32768 /dev/urandom > /tmp/lfs-cross-b/binary/test.bin")
		modifiedChecksum = sha256File(t, containerID, "/tmp/lfs-cross-b/binary/test.bin")
		assert.NotEqual(t, initialChecksum, modifiedChecksum)

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-b", "add", "binary/test.bin")
		dockerExec(
			t,
			containerID,
			"git",
			"-C",
			"/tmp/lfs-cross-b",
			"-c", "user.name=test",
			"-c", "user.email=test@replycant.local",
			"commit",
			"-m",
			"update cross-clone binary",
		)
		blob := dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-b", "show", "HEAD:binary/test.bin")
		oid := parsePointerOID(t, blob)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-b", "lfs", "push", "--object-id", "origin", oid)
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-b", "push", "origin", "main")
	})

	t.Run("clone_a_pull_and_verify_modified_binary", func(t *testing.T) {
		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-cross-a", "pull", "--rebase", "origin", "main")
		pulledChecksum := sha256File(t, containerID, "/tmp/lfs-cross-a/binary/test.bin")
		assert.Equal(t, modifiedChecksum, pulledChecksum)
	})
}

// TestE2ELFSCloneExistingRepo validates fresh clone fetch+decrypt for an existing LFS-populated repo.
func TestE2ELFSCloneExistingRepo(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	type binaryFixture struct {
		path string
		size int
	}
	files := []binaryFixture{
		{path: "binary/small.bin", size: 16384},
		{path: "binary/medium.bin", size: 65536},
		{path: "binary/large.bin", size: 262144},
	}
	checksums := map[string]string{}

	t.Run("seed_existing_lfs_repo", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-existing-src")
		dockerExec(t, containerID, "mkdir", "-p", "/tmp/lfs-existing-src/binary")

		for _, f := range files {
			dockerExec(
				t,
				containerID,
				"sh",
				"-c",
				fmt.Sprintf("head -c %d /dev/urandom > /tmp/lfs-existing-src/%s", f.size, f.path),
			)
			checksums[f.path] = sha256File(t, containerID, "/tmp/lfs-existing-src/"+f.path)
			dockerExec(t, containerID, "git", "-C", "/tmp/lfs-existing-src", "add", f.path)
			dockerExec(
				t,
				containerID,
				"git",
				"-C",
				"/tmp/lfs-existing-src",
				"-c", "user.name=test",
				"-c", "user.email=test@replycant.local",
				"commit",
				"-m",
				"add "+f.path,
			)
			blob := dockerExec(t, containerID, "git", "-C", "/tmp/lfs-existing-src", "show", "HEAD:"+f.path)
			assert.Contains(t, blob, "version https://git-lfs.github.com/spec/v1")
			assert.Contains(t, blob, "x-replycant-kek-epoch")
			assert.Contains(t, blob, "x-replycant-wrapped-dek")
		}

		dockerExec(t, containerID, "git", "-C", "/tmp/lfs-existing-src", "push", "origin", "main")
	})

	t.Run("fresh_clone_fetches_and_decrypts_all_binaries", func(t *testing.T) {
		cloneAndProvision(t, containerID, "/tmp/lfs-existing-dst")

		for _, f := range files {
			clonedChecksum := sha256File(t, containerID, "/tmp/lfs-existing-dst/"+f.path)
			assert.Equal(t, checksums[f.path], clonedChecksum)
		}
	})
}

// TestE2EBareClone validates clone bootstrap behavior for bare repository targets.
func TestE2EBareClone(t *testing.T) {
	t.Parallel()
	containerID := startContainer(t)

	cloneAndProvisionBare(t, containerID, "/tmp/bare-clone")

	assert.Equal(t, "true", strings.TrimSpace(dockerExec(t, containerID, "git", "-C", "/tmp/bare-clone", "config", "core.bare")))
	assert.Contains(t, dockerExec(t, containerID, "git", "-C", "/tmp/bare-clone", "branch", "-r"), "origin/main")
	assert.NotEmpty(t, strings.TrimSpace(dockerExec(t, containerID, "git", "-C", "/tmp/bare-clone", "config", "http.sslCAInfo")))
	_, err := dockerExecAllowFail(containerID, "test", "-d", "/tmp/bare-clone/manifests")
	assert.Error(t, err)
}
