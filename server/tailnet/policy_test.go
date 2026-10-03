package tailnet_test

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/server/tailnet"
)

// The compose file is the only place the policy exists, so these tests read
// the real artifact rather than a copy. A copy would pass while the deployed
// policy drifted, which is the exact failure that would leave a tailnet
// silently wide open.
const composePath = "../../docker-compose.yaml"

// A headscale policy in the shape the tests need to reason about. Only the
// fields that carry authorization meaning are modelled; headscale accepts
// more, and ignoring the rest keeps these tests from failing on additions.
type policyDocument struct {
	TagOwners map[string][]string `json:"tagOwners"`
	ACLs      []struct {
		Action   string   `json:"action"`
		Protocol string   `json:"proto"`
		Source   []string `json:"src"`
		Dest     []string `json:"dst"`
	} `json:"acls"`
}

// Pulls the policy out of the heredoc headscale-config writes.
//
// Parsing compose rather than templating the policy from Go keeps one source
// of truth: whatever the container writes is what is asserted here.
func loadComposePolicy(t *testing.T) policyDocument {
	t.Helper()

	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	// The heredoc body is indented by the surrounding YAML block scalar, and
	// JSON does not care, so the indentation is left in place.
	body := regexp.MustCompile(`(?s)cat > /data/config/policy\.json << POLEOF\n(.*?)\n\s*POLEOF`)
	match := body.FindSubmatch(compose)
	if match == nil {
		t.Fatal("headscale-config must write /data/config/policy.json; no heredoc found")
	}

	var policy policyDocument
	if err := json.Unmarshal(match[1], &policy); err != nil {
		t.Fatalf("the policy headscale-config writes is not valid JSON: %v", err)
	}
	return policy
}

// The whole point of the policy: a compromised or curious device must not be
// able to reach the other devices in the household. Without an explicit rule
// naming devices as a destination, headscale's default deny takes over.
func TestPolicyNeverAllowsDeviceToDeviceTraffic(t *testing.T) {
	policy := loadComposePolicy(t)

	for _, rule := range policy.ACLs {
		for _, destination := range rule.Dest {
			if strings.HasPrefix(destination, "tag:device") {
				t.Errorf("rule %+v names a device as a destination; devices must be unreachable",
					rule)
			}
		}
	}
}

// A wildcard on either side would defeat the policy no matter what else it
// says, and is the easiest mistake to make when editing it by hand.
func TestPolicyUsesNoWildcards(t *testing.T) {
	policy := loadComposePolicy(t)

	for _, rule := range policy.ACLs {
		for _, selector := range append(append([]string{}, rule.Source...), rule.Dest...) {
			if selector == "*" || strings.HasPrefix(selector, "*:") {
				t.Errorf("rule %+v uses a wildcard selector %q", rule, selector)
			}
		}
	}
}

// Devices still have to reach the server, and only on the ports gitd actually
// serves on the tailnet: the mTLS Git listener and the control-plane relay.
// Pinning the ports is what stops the rule from quietly widening to all ports.
func TestPolicyAllowsDevicesToReachOnlyTheServerPorts(t *testing.T) {
	policy := loadComposePolicy(t)

	allowed := map[string]bool{}
	for _, rule := range policy.ACLs {
		if rule.Action != "accept" {
			t.Errorf("rule %+v has action %q; only accept rules are meaningful in headscale",
				rule, rule.Action)
			continue
		}
		if len(rule.Source) != 1 || rule.Source[0] != "tag:device" {
			t.Errorf("rule %+v must be sourced from tag:device only", rule)
			continue
		}
		// Both listeners are TCP, so anything else reaching the server is by
		// definition not something we meant to allow.
		if rule.Protocol != "tcp" {
			t.Errorf("rule %+v must be restricted to tcp, got %q", rule, rule.Protocol)
		}
		for _, destination := range rule.Dest {
			allowed[destination] = true
		}
	}

	for _, want := range []string{"tag:server:8443", "tag:server:8444"} {
		if !allowed[want] {
			t.Errorf("devices must be allowed to reach %s, got destinations %v", want, allowed)
		}
		delete(allowed, want)
	}
	if len(allowed) > 0 {
		t.Errorf("policy allows unexpected destinations %v", allowed)
	}
}

// headscale refuses a pre-auth key carrying a tag that no owner claims, so a
// missing tagOwners entry surfaces as nodes failing to join rather than as a
// policy error. The constants are checked rather than literals because they
// are what gitd and hsproxy actually mint keys with.
func TestPolicyDeclaresOwnersForBothTags(t *testing.T) {
	policy := loadComposePolicy(t)

	for _, tag := range []string{tailnet.ServerTag, tailnet.DeviceTag} {
		owners, ok := policy.TagOwners[tag]
		if !ok {
			t.Errorf("tagOwners must claim %s", tag)
			continue
		}
		if len(owners) == 0 {
			t.Errorf("tagOwners for %s must name at least one owner", tag)
		}
	}
}

// The policy is only consulted if headscale is told to read it from disk. The
// default database mode leaves headscale allow-all until something writes a
// policy over the API, which nothing does.
func TestHeadscaleIsConfiguredToLoadThePolicyFile(t *testing.T) {
	compose, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("read the compose file: %v", err)
	}

	rendered := string(compose)
	if !strings.Contains(rendered, "mode: file") {
		t.Error("headscale's policy mode must be file, or the policy is never loaded")
	}
	if !strings.Contains(rendered, "path: /etc/headscale/policy.json") {
		t.Error("headscale must be pointed at the policy file headscale-config writes")
	}
}
