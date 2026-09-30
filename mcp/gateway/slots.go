package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

var (
	errSlotFree        = errors.New("slot is free")
	errSlotOutOfRange  = errors.New("slot out of range")
	errSlotUnavailable = errors.New("slot upstream unavailable")
)

type slotUpstream struct {
	host  string
	token string
}

func slotUpstreamFor(registry gatewayRegistry, slot int) (slotAssignment, error) {
	if slot < 1 || slot > registry.Size {
		return slotAssignment{}, errSlotOutOfRange
	}
	assignment, ok := registry.Slots[strconv.Itoa(slot)]
	if !ok {
		return slotAssignment{}, errSlotFree
	}
	return assignment, nil
}

func readProtectedFile(path string, minBytes int) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("%s is not a regular file", path)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	if len(value) < minBytes {
		return "", fmt.Errorf("%s is unexpectedly short", path)
	}
	return value, nil
}

func (c *gatewayConfig) slotCapabilityToken(slot int) (string, error) {
	return readProtectedFile(filepath.Join(c.TokensDir, strconv.Itoa(slot)), 32)
}

func (c *gatewayConfig) resolveUpstream(assignment slotAssignment) (slotUpstream, error) {
	if assignment.WorkspaceHash == "" {
		return slotUpstream{}, errSlotUnavailable
	}
	metadataPath := filepath.Join(
		c.HomeStorage, ".ai-sandbox", "mcp-winx",
		assignment.WorkspaceHash, "runtime", "metadata.json",
	)
	raw, err := os.ReadFile(metadataPath)
	if err != nil {
		return slotUpstream{}, errSlotUnavailable
	}
	var metadata struct {
		Transport string          `json:"transport"`
		HostPort  json.RawMessage `json:"host_port"`
	}
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return slotUpstream{}, errSlotUnavailable
	}
	port, err := parseHostPort(metadata.HostPort)
	if err != nil || metadata.Transport != "streamable-http" {
		return slotUpstream{}, errSlotUnavailable
	}
	tokenPath := filepath.Join(
		c.SecretsStorage, "mcp", assignment.WorkspaceHash, "bearer-token",
	)
	token, err := readProtectedFile(tokenPath, 32)
	if err != nil {
		return slotUpstream{}, errSlotUnavailable
	}
	return slotUpstream{
		host:  net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		token: token,
	}, nil
}

// parseHostPort accepts both JSON numbers and the string form written by
// older metadata files, so pre-existing workspace state keeps routing.
func parseHostPort(raw json.RawMessage) (int, error) {
	if len(raw) == 0 {
		return 0, errSlotUnavailable
	}
	port, err := strconv.Atoi(strings.Trim(string(raw), "\""))
	if err != nil || port < 1 || port > 65535 {
		return 0, errSlotUnavailable
	}
	return port, nil
}
