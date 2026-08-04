package transcoded

import (
	"encoding/base64"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
)

// Client for fetching media objects from upstream server
type UpstreamClient struct {
	baseURL  string
	client   *http.Client
	username string
	password string
}

// Creates a new upstream client with the specified base URL (may include Basic Auth credentials)
func NewUpstreamClient(baseURLStr string) *UpstreamClient {
	parsedURL, err := url.Parse(baseURLStr)
	if err != nil {
		log.Printf("WARNING: Failed to parse upstream URL, using as-is: %v", err)
		return &UpstreamClient{
			baseURL: strings.TrimSuffix(baseURLStr, "/"),
			client: &http.Client{
				Timeout: 0,
			},
		}
	}

	var username, password string
	if parsedURL.User != nil {
		username = parsedURL.User.Username()
		password, _ = parsedURL.User.Password()
	}

	return &UpstreamClient{
		baseURL:  strings.TrimSuffix(parsedURL.String(), "/"),
		username: username,
		password: password,
		client: &http.Client{
			Timeout: 0, // No timeout - let ffmpeg control when to close
		},
	}
}

// Returns the full URL for an object by hash, for direct access by FFmpeg
func (c *UpstreamClient) GetObjectURL(hash string) string {
	return fmt.Sprintf("%s/objects/%s", c.baseURL, hash)
}

// Returns HTTP headers string for FFmpeg -headers option.
// Includes required upstream headers and optional decryptd pass-through headers.
func (c *UpstreamClient) GetHeaders(decryptHeaders *DecryptionHeaders) string {
	headers := "Accept: application/vnd.git-lfs\r\n"
	if c.username != "" {
		auth := c.username + ":" + c.password
		headers += "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(auth)) + "\r\n"
	}
	if decryptHeaders != nil {
		headers += HeaderDEK + ": " + decryptHeaders.DEK + "\r\n"
	}
	return headers
}
