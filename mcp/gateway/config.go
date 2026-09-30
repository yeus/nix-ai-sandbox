package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

type gatewayConfig struct {
	Bind           string `json:"bind"`
	Registry       string `json:"registry"`
	TokensDir      string `json:"tokens_dir"`
	SecretsStorage string `json:"secrets_storage"`
	HomeStorage    string `json:"home_storage"`
}

func loadGatewayConfig(path string) (gatewayConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return gatewayConfig{}, fmt.Errorf("read gateway config: %w", err)
	}
	var cfg gatewayConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return gatewayConfig{}, fmt.Errorf("parse gateway config: %w", err)
	}
	for name, value := range map[string]string{
		"bind":            cfg.Bind,
		"registry":        cfg.Registry,
		"tokens_dir":      cfg.TokensDir,
		"secrets_storage": cfg.SecretsStorage,
		"home_storage":    cfg.HomeStorage,
	} {
		if value == "" {
			return gatewayConfig{}, fmt.Errorf("gateway config field %q is required", name)
		}
	}
	return cfg, nil
}

type slotAssignment struct {
	Workspace     string `json:"workspace"`
	WorkspaceHash string `json:"workspace_hash"`
	Connection    string `json:"connection"`
}

type gatewayRegistry struct {
	Version   int                       `json:"version"`
	Size      int                       `json:"size"`
	Auth      string                    `json:"auth"`
	Port      int                       `json:"port"`
	PublicURL string                    `json:"public_url"`
	Slots     map[string]slotAssignment `json:"slots"`
}

type registryCache struct {
	path   string
	mu     sync.Mutex
	loaded bool
	mtime  time.Time
	size   int64
	data   gatewayRegistry
}

func (c *registryCache) load() (gatewayRegistry, error) {
	info, err := os.Stat(c.path)
	if err != nil {
		return gatewayRegistry{}, fmt.Errorf("stat gateway registry: %w", err)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded && info.ModTime().Equal(c.mtime) && info.Size() == c.size {
		return c.data, nil
	}
	raw, err := os.ReadFile(c.path)
	if err != nil {
		return gatewayRegistry{}, fmt.Errorf("read gateway registry: %w", err)
	}
	var registry gatewayRegistry
	if err := json.Unmarshal(raw, &registry); err != nil {
		return gatewayRegistry{}, fmt.Errorf("parse gateway registry: %w", err)
	}
	c.data = registry
	c.mtime = info.ModTime()
	c.size = info.Size()
	c.loaded = true
	return registry, nil
}
