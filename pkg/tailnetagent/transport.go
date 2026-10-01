package tailnetagent

import (
	"errors"
	"net/http"
	"strings"

	"github.com/mr-andreas/replycant/pkg/lfsclient"
)

// HTTPClient is the mTLS client used for LFS once a repository is on the tailnet.
//
// The proxy is required. Without it the client would dial gitd on the host
// network, and gitd is not listening there.
func HTTPClient(caPath, certPath, keyPath, proxyURL string) (*http.Client, error) {
	if strings.TrimSpace(proxyURL) == "" {
		return nil, errors.New("tailnet proxy URL is required")
	}
	return lfsclient.NewMTLSHTTPClient(caPath, certPath, keyPath, proxyURL)
}
