package lfs

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
)

const (
	lfsMetaMediaType    = "application/vnd.git-lfs+json"
	lfsContentMediaType = "application/vnd.git-lfs"
	objectCacheControl  = "public, max-age=31536000, immutable"
)

// Handler serves the Git LFS basic-transfer API from a file-backed store. It is
// mounted under a public prefix (typically /lfs) so batch action hrefs can be
// built from the live request host without a reverse-proxy rewrite step.
type Handler struct {
	store      *Store
	pathPrefix string
	readOnly   bool
}

// batchRequest is the client payload for POST /objects/batch.
type batchRequest struct {
	Operation string            `json:"operation"`
	Transfers []string          `json:"transfers,omitempty"`
	Ref       *batchRequestRef  `json:"ref,omitempty"`
	Objects   []batchObjectSpec `json:"objects"`
}

type batchRequestRef struct {
	Name string `json:"name"`
}

type batchObjectSpec struct {
	OID  string `json:"oid"`
	Size int64  `json:"size"`
}

type batchResponse struct {
	Transfer string                `json:"transfer,omitempty"`
	Objects  []batchObjectResponse `json:"objects"`
}

type batchObjectResponse struct {
	OID     string                  `json:"oid"`
	Size    int64                   `json:"size"`
	Actions map[string]*batchAction `json:"actions,omitempty"`
	Error   *batchObjectError       `json:"error,omitempty"`
}

type batchAction struct {
	Href   string            `json:"href"`
	Header map[string]string `json:"header,omitempty"`
}

type batchObjectError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// NewHandler builds the authenticated public LFS API (batch + upload + download).
func NewHandler(store *Store, pathPrefix string) *Handler {
	return &Handler{
		store:      store,
		pathPrefix: strings.TrimSuffix(pathPrefix, "/"),
		readOnly:   false,
	}
}

// NewReadOnlyHandler exposes GET/HEAD object routes for the internal listener so
// unauthenticated compose-network callers can never mutate the store.
func NewReadOnlyHandler(store *Store, pathPrefix string) *Handler {
	return &Handler{
		store:      store,
		pathPrefix: strings.TrimSuffix(pathPrefix, "/"),
		readOnly:   true,
	}
}

// Store exposes the backing store for process wiring (pre-receive env, etc.).
func (h *Handler) Store() *Store {
	return h.store
}

// ServeHTTP dispatches LFS batch and object routes under the configured prefix.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if h.pathPrefix != "" {
		if path != h.pathPrefix && !strings.HasPrefix(path, h.pathPrefix+"/") {
			http.NotFound(w, r)
			return
		}
		path = strings.TrimPrefix(path, h.pathPrefix)
		if path == "" {
			path = "/"
		}
	}

	switch {
	case path == "/objects/batch":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if h.readOnly {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		h.handleBatch(w, r)
	case strings.HasPrefix(path, "/objects/"):
		oid := strings.TrimPrefix(path, "/objects/")
		if strings.Contains(oid, "/") || oid == "" {
			writeLFSError(w, http.StatusBadRequest, "invalid object path")
			return
		}
		if !ValidOID(oid) {
			writeLFSError(w, http.StatusBadRequest, "invalid oid")
			return
		}
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			h.handleGetObject(w, r, oid)
		case http.MethodPut:
			if h.readOnly {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			h.handlePutObject(w, r, oid)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	case strings.HasPrefix(path, "/locks"):
		// git-lfs treats locking 404 as unsupported and continues without locks.
		writeLFSError(w, http.StatusNotFound, "locking not supported")
	default:
		http.NotFound(w, r)
	}
}

// handleBatch negotiates basic transfer upload/download actions from store state.
func (h *Handler) handleBatch(w http.ResponseWriter, r *http.Request) {
	var req batchRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(&req); err != nil {
		writeLFSError(w, http.StatusBadRequest, "invalid batch request")
		return
	}
	if req.Operation != "upload" && req.Operation != "download" {
		writeLFSError(w, http.StatusBadRequest, "unsupported operation")
		return
	}

	objects := make([]batchObjectResponse, 0, len(req.Objects))
	for _, obj := range req.Objects {
		if !ValidOID(obj.OID) {
			objects = append(objects, batchObjectResponse{
				OID:  obj.OID,
				Size: obj.Size,
				Error: &batchObjectError{
					Code:    http.StatusBadRequest,
					Message: "invalid oid",
				},
			})
			continue
		}

		exists := h.store.Exists(obj.OID)
		rep := batchObjectResponse{OID: obj.OID, Size: obj.Size}

		switch req.Operation {
		case "download":
			if !exists {
				rep.Error = &batchObjectError{Code: http.StatusNotFound, Message: "not found"}
			} else {
				if size, ok := h.store.Size(obj.OID); ok {
					rep.Size = size
				}
				rep.Actions = map[string]*batchAction{
					"download": {
						Href:   h.objectURL(r, obj.OID),
						Header: map[string]string{"Accept": lfsContentMediaType},
					},
				}
			}
		case "upload":
			if !exists {
				rep.Actions = map[string]*batchAction{
					"upload": {
						Href:   h.objectURL(r, obj.OID),
						Header: map[string]string{"Accept": lfsContentMediaType},
					},
				}
			}
		}
		objects = append(objects, rep)
	}

	w.Header().Set("Content-Type", lfsMetaMediaType)
	_ = json.NewEncoder(w).Encode(batchResponse{
		Transfer: "basic",
		Objects:  objects,
	})
}

// handlePutObject streams an upload into the store. Existing objects answer 200
// before reading the body so Expect: 100-continue clients skip the transfer.
func (h *Handler) handlePutObject(w http.ResponseWriter, r *http.Request, oid string) {
	if h.store.Exists(oid) {
		w.WriteHeader(http.StatusOK)
		return
	}

	size := r.ContentLength
	if size < 0 {
		writeLFSError(w, http.StatusBadRequest, "content-length required")
		return
	}

	err := h.store.Put(r.Context(), oid, size, r.Body)
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		switch {
		case errors.Is(err, ErrHashMismatch), errors.Is(err, ErrSizeMismatch), errors.Is(err, ErrInvalidOID):
			writeLFSError(w, http.StatusBadRequest, err.Error())
		default:
			log.Printf("lfs upload failed oid=%s: %v", oid, err)
			writeLFSError(w, http.StatusInternalServerError, "upload failed")
		}
		return
	}
	w.WriteHeader(http.StatusOK)
}

// handleGetObject serves object bytes or metadata depending on Accept.
func (h *Handler) handleGetObject(w http.ResponseWriter, r *http.Request, oid string) {
	if wantsMetadata(r.Header.Get("Accept")) {
		h.handleGetMeta(w, r, oid)
		return
	}
	h.handleGetContent(w, r, oid)
}

// handleGetMeta answers the LFS metadata route used by decryptd for object size.
func (h *Handler) handleGetMeta(w http.ResponseWriter, r *http.Request, oid string) {
	size, ok := h.store.Size(oid)
	if !ok {
		writeLFSError(w, http.StatusNotFound, "not found")
		return
	}
	w.Header().Set("Content-Type", lfsMetaMediaType)
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"oid":  oid,
		"size": size,
	})
}

// handleGetContent streams object bytes through ServeContent so Range, ETag,
// and conditional requests stay correct without buffering the object.
func (h *Handler) handleGetContent(w http.ResponseWriter, r *http.Request, oid string) {
	f, info, err := h.store.Open(oid)
	if err != nil {
		if errors.Is(err, ErrNotFound) || errors.Is(err, ErrInvalidOID) {
			writeLFSError(w, http.StatusNotFound, "not found")
			return
		}
		writeLFSError(w, http.StatusInternalServerError, "open failed")
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("ETag", `"`+oid+`"`)
	w.Header().Set("Cache-Control", objectCacheControl)
	// RFC 7233 requires ignoring range units other than those we understand.
	// ServeContent returns 416 for some malformed values, so drop them first.
	if rangeHdr := r.Header.Get("Range"); rangeHdr != "" && !strings.HasPrefix(rangeHdr, "bytes=") {
		r = r.Clone(r.Context())
		r.Header.Del("Range")
	}
	http.ServeContent(w, r, "", info.ModTime(), f)
}

// objectURL builds a public action href from the active request host and prefix.
func (h *Handler) objectURL(r *http.Request, oid string) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	u := url.URL{
		Scheme: scheme,
		Host:   r.Host,
		Path:   h.pathPrefix + "/objects/" + oid,
	}
	return u.String()
}

// wantsMetadata selects the JSON metadata route when Accept asks for +json.
func wantsMetadata(accept string) bool {
	media := strings.TrimSpace(strings.Split(accept, ";")[0])
	return media == lfsMetaMediaType || strings.HasSuffix(media, "+json")
}

// writeLFSError returns a JSON error body for LFS clients that expect +json.
func writeLFSError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", lfsMetaMediaType)
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `{"message":%q}`, message)
}
