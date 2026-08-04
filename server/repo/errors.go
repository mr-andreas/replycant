package repo

import "errors"

var (
	ErrManifestAndBinarySet    = errors.New("manifest and binary are mutually exclusive")
	ErrManifestAndBinaryNotSet = errors.New("manifest or binary must be set")
)
