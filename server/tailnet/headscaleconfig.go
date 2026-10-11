package tailnet

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"text/template"

	"github.com/mr-andreas/replycant/pkg/tailnetaddr"
)

// Where headscale reads the policy. The config points here, and every
// deployment mounts the rendered files at /etc/headscale.
const HeadscalePolicyPath = "/etc/headscale/policy.json"

// The headscale user every node is registered under. Tags are owned by it.
const headscaleUser = "replycant"

//go:embed headscale.yaml.tmpl
var headscaleConfigTemplate string

// What differs between deployments: compose publishes headscale on the
// compose network, the integration harness on loopback.
type HeadscaleConfigSettings struct {
	// The URL headscale tells nodes it is reached at: the tunnel hostname
	// in production.
	ServerURL string

	// Where headscale listens for hsproxy and gitd.
	ListenAddr string
}

// Renders headscale's config.yaml.
//
// Generated rather than written by hand so the tailnet domain and policy path
// come from the same constants clients and tests use.
func RenderHeadscaleConfig(settings HeadscaleConfigSettings) ([]byte, error) {
	if strings.TrimSpace(settings.ServerURL) == "" {
		return nil, errors.New("headscale config needs a server URL")
	}
	if strings.TrimSpace(settings.ListenAddr) == "" {
		return nil, errors.New("headscale config needs a listen address")
	}
	tmpl, err := template.New("headscale.yaml").Parse(headscaleConfigTemplate)
	if err != nil {
		return nil, fmt.Errorf("parse headscale config template: %w", err)
	}
	var out bytes.Buffer
	err = tmpl.Execute(&out, map[string]string{
		"ServerURL":  settings.ServerURL,
		"ListenAddr": settings.ListenAddr,
		"PolicyPath": HeadscalePolicyPath,
		"BaseDomain": tailnetaddr.Domain,
	})
	if err != nil {
		return nil, fmt.Errorf("render headscale config: %w", err)
	}
	return out.Bytes(), nil
}

type headscalePolicy struct {
	TagOwners map[string][]string `json:"tagOwners"`
	ACLs      []headscaleACL      `json:"acls"`
}

type headscaleACL struct {
	Action   string   `json:"action"`
	Protocol string   `json:"proto"`
	Source   []string `json:"src"`
	Dest     []string `json:"dst"`
}

// Renders headscale's policy.json.
//
// The tailnet exists so devices can reach this household's server, not each
// other. Naming only the server as a destination leaves everything else to
// headscale's default deny, so a compromised phone cannot reach the other
// devices. The port is pinned to the one gitd serves on the tailnet, and nothing
// grants the server access to devices, because it never initiates.
//
// Built from the same tags and ports gitd and hsproxy use, so the policy
// cannot drift from them. Owners carry a trailing @ because headscale's
// policy v2 requires it.
func RenderHeadscalePolicy() ([]byte, error) {
	owner := headscaleUser + "@"
	policy := headscalePolicy{
		TagOwners: map[string][]string{
			ServerTag: {owner},
			DeviceTag: {owner},
		},
		ACLs: []headscaleACL{{
			Action:   "accept",
			Protocol: "tcp",
			Source:   []string{DeviceTag},
			Dest: []string{
				fmt.Sprintf("%s:%d", ServerTag, tailnetaddr.GitdPort),
			},
		}},
	}
	return json.MarshalIndent(policy, "", "  ")
}
