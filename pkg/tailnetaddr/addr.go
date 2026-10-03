// Package tailnetaddr holds the addresses every client uses to reach gitd
// once it is on the deployment's tailnet.
//
// These are not delivered in pairing records or QR codes because they are a
// property of the gitd build, not of a deployment. A device only ever talks
// to a gitd from the same release, and a name that came from a QR could
// drift from the certificate SAN and the headscale policy.
package tailnetaddr

import "fmt"

const (
	// MagicDNS name gitd registers on the tailnet. Must match the SAN on
	// gitd's certificate and the hostname compose passes to tsnet.
	GitdHost = "gitd.replycant.internal"

	// Port gitd serves Git and LFS on inside the tailnet. Must stay in
	// step with the headscale policy; a device dialling anything else is
	// refused before gitd sees it.
	GitdPort = 8443

	// Port gitd relays control-plane traffic on inside the tailnet. Must
	// match --tailnet-control-addr.
	ControlPort = 8444

	// Path on the control-plane host (hsproxy) where a device whose key is
	// in pubkeys/ asks for a fresh single-use pre-auth key. It lives on the
	// control plane rather than on gitd because a device that headscale has
	// forgotten is not on the tailnet and cannot reach gitd. hsproxy answers
	// it from the same mTLS session it would otherwise splice to headscale.
	PreauthKeyPath = "/replycant/preauthkey"
)

// URL clients use for Git and LFS after they have joined the tailnet.
func GitdURL() string {
	return fmt.Sprintf("https://%s:%d", GitdHost, GitdPort)
}

// Where a joined device should send control-plane traffic so it can stop
// depending on the hosted relay.
func ControlAddr() string {
	return fmt.Sprintf("%s:%d", GitdHost, ControlPort)
}
