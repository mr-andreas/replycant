package lfs

import (
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Object represents one LFS object identity used for server-side existence checks.
type Object struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

const pointerVersionLine = "version https://git-lfs.github.com/spec/v1"
const verifyBatchSize = 100

// ParsePointer extracts the OID and size from a Git LFS pointer file to distinguish it from regular blobs.
func ParsePointer(content string) (oid string, size int64, ok bool) {
	lines := strings.Split(content, "\n")

	var (
		hasVersion bool
		hasOID     bool
		hasSize    bool
	)

	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}

		switch {
		case line == pointerVersionLine:
			hasVersion = true
		case strings.HasPrefix(line, "oid sha256:"):
			candidate := strings.TrimPrefix(line, "oid sha256:")
			if len(candidate) != 64 {
				return "", 0, false
			}
			if _, err := hex.DecodeString(candidate); err != nil {
				return "", 0, false
			}
			oid = strings.ToLower(candidate)
			hasOID = true
		case strings.HasPrefix(line, "size "):
			candidate := strings.TrimSpace(strings.TrimPrefix(line, "size "))
			parsed, err := strconv.ParseInt(candidate, 10, 64)
			if err != nil || parsed < 0 {
				return "", 0, false
			}
			size = parsed
			hasSize = true
		}
	}

	if !hasVersion || !hasOID || !hasSize {
		return "", 0, false
	}

	return oid, size, true
}

// VerifyObjects checks that all requested OIDs exist in LFS so Git pushes can be atomically rejected on missing blobs.
func VerifyObjects(lfsURL string, objects []Object) ([]string, error) {
	if len(objects) == 0 {
		return nil, nil
	}

	objectBaseURL, username, password, err := objectBaseURL(lfsURL)
	if err != nil {
		return nil, err
	}

	uniqueObjects := dedupeObjects(objects)
	log.Printf(
		"lfs-verify: requesting HEAD checks endpoint=%s object_count=%d batch_size=%d",
		objectBaseURL,
		len(uniqueObjects),
		verifyBatchSize,
	)
	client := &http.Client{Timeout: 20 * time.Second}

	for start := 0; start < len(uniqueObjects); start += verifyBatchSize {
		end := start + verifyBatchSize
		if end > len(uniqueObjects) {
			end = len(uniqueObjects)
		}
		missing, err := checkObjectExistence(client, objectBaseURL, username, password, uniqueObjects[start:end])
		if err != nil {
			return nil, err
		}
		if len(missing) == 0 {
			continue
		}

		sort.Strings(missing)
		log.Printf(
			"lfs-verify: HEAD response summary requested=%d checked=%d missing=%d",
			len(uniqueObjects),
			end,
			len(missing),
		)
		log.Printf("lfs-verify: missing object oids=%s", strings.Join(missing, ","))
		return missing, nil
	}

	log.Printf("lfs-verify: HEAD response summary requested=%d missing=0", len(uniqueObjects))
	return nil, nil
}

func checkObjectExistence(client *http.Client, baseURL, username, password string, objects []Object) ([]string, error) {
	if len(objects) == 0 {
		return nil, nil
	}
	const workerCount = 2

	type result struct {
		oid     string
		missing bool
		err     error
	}

	jobs := make(chan Object)
	results := make(chan result, len(objects))

	workers := workerCount
	if len(objects) < workers {
		workers = len(objects)
	}
	for i := 0; i < workers; i++ {
		go func() {
			for obj := range jobs {
				req, err := http.NewRequest(http.MethodHead, fmt.Sprintf("%s/%s", baseURL, obj.OID), nil)
				if err != nil {
					results <- result{oid: obj.OID, err: fmt.Errorf("build lfs HEAD request for oid %s: %w", obj.OID, err)}
					continue
				}
				req.Header.Set("Accept", "application/vnd.git-lfs")
				if username != "" {
					req.SetBasicAuth(username, password)
				}

				resp, err := client.Do(req)
				if err != nil {
					results <- result{oid: obj.OID, err: fmt.Errorf("request lfs object %s: %w", obj.OID, err)}
					continue
				}
				_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1))
				resp.Body.Close()

				switch {
				case resp.StatusCode >= 200 && resp.StatusCode < 300:
					results <- result{oid: obj.OID}
				case resp.StatusCode == http.StatusNotFound:
					results <- result{
						oid:     obj.OID,
						missing: true,
					}
				default:
					log.Printf(
						"lfs-verify: HEAD check temporary failure oid=%s status=%d endpoint=%s",
						obj.OID,
						resp.StatusCode,
						baseURL,
					)
					results <- result{
						oid: obj.OID,
						err: fmt.Errorf(
							"lfs HEAD check temporary failure for oid %s: unexpected HTTP status %d",
							obj.OID,
							resp.StatusCode,
						),
					}
				}
			}
		}()
	}

	go func() {
		for _, obj := range objects {
			jobs <- obj
		}
		close(jobs)
	}()

	missing := make([]string, 0)
	for range objects {
		result := <-results
		if result.err != nil {
			return nil, result.err
		}
		if result.missing {
			missing = append(missing, result.oid)
		}
	}
	return missing, nil
}

// objectBaseURL normalizes the configured LFS base URL into the objects endpoint base.
func objectBaseURL(raw string) (endpoint string, username string, password string, err error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", "", "", fmt.Errorf("parse lfs url: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", "", "", fmt.Errorf("invalid lfs url: %q", raw)
	}

	if parsed.User != nil {
		username = parsed.User.Username()
		password, _ = parsed.User.Password()
		parsed.User = nil
	}

	basePath := strings.TrimSuffix(parsed.Path, "/")
	if basePath == "" {
		parsed.Path = "/objects"
	} else {
		parsed.Path = basePath + "/objects"
	}

	return parsed.String(), username, password, nil
}

// dedupeObjects removes duplicate OIDs so each object is checked once per push.
func dedupeObjects(objects []Object) []Object {
	seen := map[string]struct{}{}
	result := make([]Object, 0, len(objects))

	for _, obj := range objects {
		if obj.OID == "" {
			continue
		}
		if _, exists := seen[obj.OID]; exists {
			continue
		}
		seen[obj.OID] = struct{}{}
		result = append(result, obj)
	}

	return result
}
