package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestParsePktLineLength verifies pkt-line hex length decoding and malformed header handling.
func TestParsePktLineLength(t *testing.T) {
	t.Parallel()
	tests := []struct {
		header  string
		want    int
		wantErr bool
	}{
		{header: "0006", want: 6},
		{header: "0000", want: 0},
		{header: "ffff", want: 65535},
		{header: "zzzz", wantErr: true},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.header, func(t *testing.T) {
			t.Parallel()
			got, err := parsePktLineLength([]byte(tt.header))
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

// TestSplitKeyValue ensures metadata parsing accepts key=value lines and rejects invalid variants.
func TestSplitKeyValue(t *testing.T) {
	t.Parallel()
	key, value, ok := splitKeyValue("command=clean")
	assert.True(t, ok)
	assert.Equal(t, "command", key)
	assert.Equal(t, "clean", value)

	key, value, ok = splitKeyValue("pathname=manifests/foo.yaml")
	assert.True(t, ok)
	assert.Equal(t, "pathname", key)
	assert.Equal(t, "manifests/foo.yaml", value)

	key, value, ok = splitKeyValue("noequals")
	assert.False(t, ok)
	assert.Empty(t, key)
	assert.Empty(t, value)

	key, value, ok = splitKeyValue("=value")
	assert.False(t, ok)
	assert.Empty(t, key)
	assert.Equal(t, "value", value)
}

// TestPktLineRoundtrip validates packet writer/reader interoperability for headers and data payloads.
func TestPktLineRoundtrip(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	writer := NewPktLineWriter(&buf)
	require.NoError(t, writer.WriteString("command=clean\n"))
	require.NoError(t, writer.WriteString("pathname=manifests/x.yaml\n"))
	require.NoError(t, writer.WriteFlush())
	require.NoError(t, writer.WriteString("abc"))
	require.NoError(t, writer.WriteString("def"))
	require.NoError(t, writer.WriteFlush())
	require.NoError(t, writer.Flush())

	reader := NewPktLineReader(&buf)
	header, err := reader.ReadStringMapUntilFlush()
	require.NoError(t, err)
	assert.Equal(t, "clean", header["command"])
	assert.Equal(t, "manifests/x.yaml", header["pathname"])

	data, err := reader.ReadDataUntilFlush()
	require.NoError(t, err)
	assert.Equal(t, []byte("abcdef"), data)
}

// TestWriteDataFrames verifies large payload splitting still preserves exact byte content.
func TestWriteDataFrames(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	writer := NewPktLineWriter(&buf)
	reader := NewPktLineReader(&buf)

	require.NoError(t, writer.WriteDataFrames(nil))
	require.NoError(t, writer.WriteFlush())
	require.NoError(t, writer.Flush())
	data, err := reader.ReadDataUntilFlush()
	require.NoError(t, err)
	assert.Empty(t, data)

	buf.Reset()
	writer = NewPktLineWriter(&buf)
	reader = NewPktLineReader(&buf)
	large := []byte(strings.Repeat("a", (pktLineMaxLength-pktLineHeaderBytes)+123))
	require.NoError(t, writer.WriteDataFrames(large))
	require.NoError(t, writer.WriteFlush())
	require.NoError(t, writer.Flush())
	data, err = reader.ReadDataUntilFlush()
	require.NoError(t, err)
	assert.Equal(t, large, data)
}
