package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"io"
)

const (
	// pktLineHeaderBytes is the fixed ASCII hex prefix size for each pkt-line frame.
	pktLineHeaderBytes = 4
	// pktLineMaxLength follows Git's pkt-line limit for one framed payload.
	pktLineMaxLength = 65520
)

// PktLineReader parses git pkt-line frames from a stream used by long-running filters.
type PktLineReader struct {
	r *bufio.Reader
}

// PktLineWriter emits git pkt-line frames so the filter process can respond to git.
type PktLineWriter struct {
	w *bufio.Writer
}

// NewPktLineReader wraps a stream with buffered pkt-line decoding.
func NewPktLineReader(r io.Reader) *PktLineReader {
	return &PktLineReader{r: bufio.NewReader(r)}
}

// NewPktLineWriter wraps a stream with buffered pkt-line encoding.
func NewPktLineWriter(w io.Writer) *PktLineWriter {
	return &PktLineWriter{w: bufio.NewWriter(w)}
}

// ReadPacket returns one pkt-line payload and nil for a flush packet.
func (p *PktLineReader) ReadPacket() ([]byte, error) {
	header := make([]byte, pktLineHeaderBytes)
	if _, err := io.ReadFull(p.r, header); err != nil {
		return nil, err
	}
	length, err := parsePktLineLength(header)
	if err != nil {
		return nil, err
	}
	if length == 0 {
		return nil, nil
	}
	if length < pktLineHeaderBytes {
		return nil, fmt.Errorf("invalid pkt-line length %d", length)
	}
	payloadLen := length - pktLineHeaderBytes
	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(p.r, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

// ReadUntilFlush reads all payload packets until the next flush packet.
func (p *PktLineReader) ReadUntilFlush() ([][]byte, error) {
	packets := make([][]byte, 0)
	for {
		packet, err := p.ReadPacket()
		if err != nil {
			return nil, err
		}
		if packet == nil {
			return packets, nil
		}
		packets = append(packets, packet)
	}
}

// ReadStringMapUntilFlush parses key=value pkt-lines into a map until flush.
func (p *PktLineReader) ReadStringMapUntilFlush() (map[string]string, error) {
	packets, err := p.ReadUntilFlush()
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(packets))
	for _, packet := range packets {
		line := string(packet)
		if len(line) > 0 && line[len(line)-1] == '\n' {
			line = line[:len(line)-1]
		}
		key, value, ok := splitKeyValue(line)
		if !ok {
			continue
		}
		out[key] = value
	}
	return out, nil
}

// ReadDataUntilFlush joins data packets into one byte slice until a flush packet.
func (p *PktLineReader) ReadDataUntilFlush() ([]byte, error) {
	packets, err := p.ReadUntilFlush()
	if err != nil {
		return nil, err
	}
	total := 0
	for _, packet := range packets {
		total += len(packet)
	}
	out := make([]byte, 0, total)
	for _, packet := range packets {
		out = append(out, packet...)
	}
	return out, nil
}

// WritePacket writes one payload pkt-line frame.
func (p *PktLineWriter) WritePacket(payload []byte) error {
	length := len(payload) + pktLineHeaderBytes
	if length > pktLineMaxLength {
		return fmt.Errorf("pkt-line payload too large: %d", len(payload))
	}
	header := fmt.Sprintf("%04x", length)
	if _, err := p.w.WriteString(header); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := p.w.Write(payload)
	return err
}

// WriteString writes one packet payload from text.
func (p *PktLineWriter) WriteString(value string) error {
	return p.WritePacket([]byte(value))
}

// WriteFlush emits a pkt-line flush marker.
func (p *PktLineWriter) WriteFlush() error {
	_, err := p.w.WriteString("0000")
	return err
}

// WriteDataFrames splits large data into pkt-line sized payload frames.
func (p *PktLineWriter) WriteDataFrames(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	maxPayload := pktLineMaxLength - pktLineHeaderBytes
	for start := 0; start < len(data); start += maxPayload {
		end := start + maxPayload
		if end > len(data) {
			end = len(data)
		}
		if err := p.WritePacket(data[start:end]); err != nil {
			return err
		}
	}
	return nil
}

// Flush forwards buffered writes to the underlying stream.
func (p *PktLineWriter) Flush() error {
	return p.w.Flush()
}

// parsePktLineLength decodes a 4-byte ASCII hex length prefix.
func parsePktLineLength(header []byte) (int, error) {
	if len(header) != pktLineHeaderBytes {
		return 0, fmt.Errorf("invalid pkt-line header size: %d", len(header))
	}
	decoded := make([]byte, 2)
	if _, err := hex.Decode(decoded, header); err != nil {
		return 0, fmt.Errorf("invalid pkt-line length %q: %w", string(header), err)
	}
	return int(decoded[0])<<8 | int(decoded[1]), nil
}

// splitKeyValue parses "key=value" metadata lines sent by git.
func splitKeyValue(line string) (string, string, bool) {
	for i := 0; i < len(line); i++ {
		if line[i] == '=' {
			return line[:i], line[i+1:], i > 0
		}
	}
	return "", "", false
}
