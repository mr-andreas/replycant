package tailnet_test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
	"github.com/mr-andreas/replycant/server/tailnet"
	"gopkg.in/yaml.v3"
)

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

// The policy exactly as headscale-config writes it, so the deployed artifact
// is what these tests assert on.
func renderedPolicy(t *testing.T) policyDocument {
	t.Helper()
	raw, err := tailnet.RenderHeadscalePolicy()
	if err != nil {
		t.Fatalf("render the policy: %v", err)
	}
	var policy policyDocument
	if err := json.Unmarshal(raw, &policy); err != nil {
		t.Fatalf("the rendered policy is not valid JSON: %v", err)
	}
	return policy
}

// The whole point of the policy: a compromised or curious device must not be
// able to reach the other devices in the household. Without an explicit rule
// naming devices as a destination, headscale's default deny takes over.
func TestPolicyNeverAllowsDeviceToDeviceTraffic(t *testing.T) {
	for _, rule := range renderedPolicy(t).ACLs {
		for _, destination := range rule.Dest {
			if strings.HasPrefix(destination, tailnet.DeviceTag) {
				t.Errorf("rule %+v names a device as a destination; devices must be unreachable",
					rule)
			}
		}
	}
}

// A wildcard on either side would defeat the policy no matter what else it
// says.
func TestPolicyUsesNoWildcards(t *testing.T) {
	for _, rule := range renderedPolicy(t).ACLs {
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
	allowed := map[string]bool{}
	for _, rule := range renderedPolicy(t).ACLs {
		if rule.Action != "accept" {
			t.Errorf("rule %+v has action %q; only accept rules are meaningful in headscale",
				rule, rule.Action)
			continue
		}
		if len(rule.Source) != 1 || rule.Source[0] != tailnet.DeviceTag {
			t.Errorf("rule %+v must be sourced from %s only", rule, tailnet.DeviceTag)
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

	for _, port := range []int{tailnetaddr.GitdPort, tailnetaddr.ControlPort} {
		want := fmt.Sprintf("%s:%d", tailnet.ServerTag, port)
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
// policy error.
func TestPolicyDeclaresOwnersForBothTags(t *testing.T) {
	policy := renderedPolicy(t)
	for _, tag := range []string{tailnet.ServerTag, tailnet.DeviceTag} {
		if len(policy.TagOwners[tag]) == 0 {
			t.Errorf("tagOwners must claim %s", tag)
		}
	}
}

// The parts of headscale's config that replycant depends on.
type headscaleConfig struct {
	ServerURL  string `yaml:"server_url"`
	ListenAddr string `yaml:"listen_addr"`
	Noise      struct {
		PrivateKeyPath string `yaml:"private_key_path"`
	} `yaml:"noise"`
	TrustedProxies []string `yaml:"trusted_proxies"`
	Database       struct {
		SQLite struct {
			Path string `yaml:"path"`
		} `yaml:"sqlite"`
	} `yaml:"database"`
	DERP struct {
		Server struct {
			Enabled bool `yaml:"enabled"`
		} `yaml:"server"`
	} `yaml:"derp"`
	Policy struct {
		Mode string `yaml:"mode"`
		Path string `yaml:"path"`
	} `yaml:"policy"`
	DNS struct {
		MagicDNS   bool   `yaml:"magic_dns"`
		BaseDomain string `yaml:"base_domain"`
	} `yaml:"dns"`
}

func renderedConfig(t *testing.T) headscaleConfig {
	t.Helper()
	raw, err := tailnet.RenderHeadscaleConfig(tailnet.HeadscaleConfigSettings{
		ServerURL:  "https://hs.example.com",
		ListenAddr: "0.0.0.0:8080",
	})
	if err != nil {
		t.Fatalf("render the config: %v", err)
	}
	var config headscaleConfig
	if err := yaml.Unmarshal(raw, &config); err != nil {
		t.Fatalf("the rendered config is not valid YAML: %v", err)
	}
	return config
}

// headscale bakes server_url into what it tells nodes, and compose and the
// integration harness listen on different addresses, so both are inputs.
func TestConfigCarriesTheServerURLAndListenAddress(t *testing.T) {
	config := renderedConfig(t)
	if config.ServerURL != "https://hs.example.com" {
		t.Errorf("server_url = %q", config.ServerURL)
	}
	if config.ListenAddr != "0.0.0.0:8080" {
		t.Errorf("listen_addr = %q", config.ListenAddr)
	}
}

// The policy is only consulted if headscale is told to read it from disk. The
// default database mode leaves headscale allow-all until something writes a
// policy over the API, which nothing does.
func TestConfigLoadsThePolicyFile(t *testing.T) {
	config := renderedConfig(t)
	if config.Policy.Mode != "file" {
		t.Errorf("policy mode must be file, got %q", config.Policy.Mode)
	}
	if config.Policy.Path != tailnet.HeadscalePolicyPath {
		t.Errorf("policy path must be %s, got %q", tailnet.HeadscalePolicyPath, config.Policy.Path)
	}
}

// Clients dial gitd by MagicDNS name, and that name is a build constant. A
// different base domain would leave every client resolving nothing.
func TestConfigServesTheFixedTailnetDomain(t *testing.T) {
	config := renderedConfig(t)
	if !config.DNS.MagicDNS || config.DNS.BaseDomain != tailnetaddr.Domain {
		t.Errorf("MagicDNS must serve %s, got magic_dns=%t base_domain=%q",
			tailnetaddr.Domain, config.DNS.MagicDNS, config.DNS.BaseDomain)
	}
}

// The noise key is the control plane's identity, and every client pins it.
// Keeping it out of the database directory is what lets an operator delete
// that directory without every node rejecting the restarted headscale.
func TestConfigKeepsTheNoiseKeyOutsideTheDatabaseDirectory(t *testing.T) {
	config := renderedConfig(t)
	if !strings.HasPrefix(config.Noise.PrivateKeyPath, "/var/lib/headscale-noise/") {
		t.Errorf("noise key must live outside /var/lib/headscale, got %q", config.Noise.PrivateKeyPath)
	}
	if !strings.HasPrefix(config.Database.SQLite.Path, "/var/lib/headscale/") {
		t.Errorf("database must live in /var/lib/headscale, got %q", config.Database.SQLite.Path)
	}
}

// hsproxy splices raw TCP and adds no X-Forwarded-For, so trusting a proxy
// would only let clients spoof their logged address. The embedded DERP server
// needs public UDP the reverse tunnel cannot provide.
func TestConfigTrustsNoProxyAndRunsNoDERP(t *testing.T) {
	config := renderedConfig(t)
	if len(config.TrustedProxies) != 0 {
		t.Errorf("trusted_proxies must be empty, got %v", config.TrustedProxies)
	}
	if config.DERP.Server.Enabled {
		t.Error("the embedded DERP server must stay disabled")
	}
}

// A config with no server URL or listen address would start headscale in a
// state no client can register against.
func TestConfigRejectsMissingSettings(t *testing.T) {
	for _, settings := range []tailnet.HeadscaleConfigSettings{
		{ListenAddr: "0.0.0.0:8080"},
		{ServerURL: "https://hs.example.com"},
	} {
		if _, err := tailnet.RenderHeadscaleConfig(settings); err == nil {
			t.Errorf("settings %+v must be rejected", settings)
		}
	}
}
