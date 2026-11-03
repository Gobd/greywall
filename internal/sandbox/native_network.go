package sandbox

import (
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"os"
)

// NativeDestination is deliberately exact: no implicit wildcard, DNS expansion,
// subnet or protocol widening. Shared project policy schema, usable by backends.
type NativeDestination struct {
	Address   string `json:"address"`
	Port      uint16 `json:"port"`
	Transport string `json:"transport"`
}

type NativeNetworkPolicy struct {
	SchemaVersion int                 `json:"schemaVersion"`
	Destinations  []NativeDestination `json:"destinations"`
	// Explicit runtime acknowledgment; never inferred from a saved policy.
	BestEffort bool `json:"-"`
}

func LoadNativeNetworkPolicy(path string) (*NativeNetworkPolicy, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return &NativeNetworkPolicy{SchemaVersion: 1}, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 2*1024*1024 {
		return nil, fmt.Errorf("native policy must be a regular file smaller than 2 MiB")
	}
	file, err := os.Open(path) //nolint:gosec // explicit project policy path
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()
	decoder := json.NewDecoder(io.LimitReader(file, 2*1024*1024+1))
	decoder.DisallowUnknownFields()
	var policy NativeNetworkPolicy
	if err := decoder.Decode(&policy); err != nil {
		return nil, fmt.Errorf("invalid native project policy: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("native policy must contain exactly one JSON object")
	}
	if err := policy.Validate(); err != nil {
		return nil, err
	}
	return &policy, nil
}

// Validate is also required for callers constructing policies directly.
func (policy *NativeNetworkPolicy) Validate() error {
	if policy == nil || policy.SchemaVersion != 1 {
		return fmt.Errorf("unsupported or missing native policy schema")
	}
	for _, destination := range policy.Destinations {
		ip, err := netip.ParseAddr(destination.Address)
		if err != nil || ip.Zone() != "" || destination.Port == 0 ||
			(destination.Transport != "tcp" && destination.Transport != "udp") {
			return fmt.Errorf("native kernel policy requires exact IP, nonzero port, tcp/udp: %+v", destination)
		}
	}
	return nil
}
