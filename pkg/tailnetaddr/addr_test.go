package tailnetaddr

import "testing"

// Clients, certificates, and the headscale policy all have to name the same
// host and ports. A drift here would leave a freshly joined device unable to
// reach gitd, or falling back to the relay forever.
func TestGitdURLIsTheHardcodedTailnetAddress(t *testing.T) {
	if GitdURL() != "https://gitd.replycant.internal:8443" {
		t.Errorf("GitdURL() = %q", GitdURL())
	}
}
