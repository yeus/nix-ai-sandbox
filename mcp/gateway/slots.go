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
		Transport string `json:"transport"`
		HostPort  int    `json:"host_port"`
	}
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return slotUpstream{}, errSlotUnavailable
	}
	if metadata.Transport != "streamable-http" || metadata.HostPort < 1 || metadata.HostPort > 65535 {
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
		host:  net.JoinHostPort("127.0.0.1", strconv.Itoa(metadata.HostPort)),
		token: token,
	}, nil
}
