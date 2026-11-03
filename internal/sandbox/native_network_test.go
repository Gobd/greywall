package sandbox

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadNativePolicy(t *testing.T) {
	tests := []struct {
		name string
		data string
		ok   bool
	}{
		{"empty allowlist", `{"schemaVersion":1,"destinations":[]}`, true},
		{"ipv4 tcp", `{"schemaVersion":1,"destinations":[{"address":"127.0.0.1","port":80,"transport":"tcp"}]}`, true},
		{"ipv6 udp", `{"schemaVersion":1,"destinations":[{"address":"::1","port":53,"transport":"udp"}]}`, true},
		{"wildcard", `{"schemaVersion":1,"destinations":[{"address":"*","port":443,"transport":"tcp"}]}`, false},
		{"hostname", `{"schemaVersion":1,"destinations":[{"address":"example.com","port":443,"transport":"tcp"}]}`, false},
		{"zone", `{"schemaVersion":1,"destinations":[{"address":"fe80::1%en0","port":443,"transport":"tcp"}]}`, false},
		{"zero port", `{"schemaVersion":1,"destinations":[{"address":"127.0.0.1","port":0,"transport":"tcp"}]}`, false},
		{"oversize port", `{"schemaVersion":1,"destinations":[{"address":"127.0.0.1","port":65536,"transport":"tcp"}]}`, false},
		{"protocol", `{"schemaVersion":1,"destinations":[{"address":"127.0.0.1","port":443,"transport":"any"}]}`, false},
		{"wrong version", `{"schemaVersion":2,"destinations":[]}`, false},
		{"unknown field", `{"schemaVersion":1,"destinations":[],"allowAll":true}`, false},
		{"trailing document", `{"schemaVersion":1,"destinations":[]} {}`, false},
		{"malformed", `{`, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "network.json")
			if err := os.WriteFile(path, []byte(tc.data), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := LoadNativeNetworkPolicy(path)
			if (err == nil) != tc.ok {
				t.Fatalf("ok=%v, error=%v", tc.ok, err)
			}
		})
	}
}

func TestNativePolicyMissingDeniesAndSymlinkRejected(t *testing.T) {
	path := filepath.Join(t.TempDir(), "network.json")
	policy, err := LoadNativeNetworkPolicy(path)
	if err != nil || len(policy.Destinations) != 0 {
		t.Fatalf("missing policy should deny all: %v", err)
	}
	target := path + ".real"
	if err := os.WriteFile(target, []byte(`{"schemaVersion":1,"destinations":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadNativeNetworkPolicy(path); err == nil {
		t.Fatal("symlinked policy accepted")
	}
}

func TestNativeKernelDenyAllHasNoLegacyLocalhost(t *testing.T) {
	policy := &NativeNetworkPolicy{SchemaVersion: 1}
	profile := GenerateSandboxProfile(MacOSSandboxParams{NeedsNetworkRestriction: true, NativePolicy: policy, AllowLocalOutbound: true, ForwardPorts: []int{9876}})
	for _, forbidden := range []string{"(allow network*)", "(allow network-outbound)\n", `(allow network-outbound (local ip "localhost:*"))`, `localhost:9876`} {
		if strings.Contains(profile, forbidden) {
			t.Errorf("enforcing profile widened access: %s", forbidden)
		}
	}
}

func TestNativeKernelLearningAndBestEffortRequireExplicitOptIn(t *testing.T) {
	policy := &NativeNetworkPolicy{SchemaVersion: 1, Destinations: []NativeDestination{{Address: "*", Port: 443, Transport: "tcp"}, {Address: "127.0.0.1", Port: 1, Transport: "udp) (allow network*)"}}}
	profile := GenerateSandboxProfile(MacOSSandboxParams{NeedsNetworkRestriction: true, NativePolicy: policy})
	if strings.Contains(profile, "(allow network*)") || strings.Contains(profile, `remote tcp "*:443"`) {
		t.Fatal("invalid in-memory grants widened kernel profile")
	}
	if policy.Validate() == nil {
		t.Fatal("invalid in-memory policy was accepted")
	}
	profile = GenerateSandboxProfile(MacOSSandboxParams{NeedsNetworkRestriction: true, NativePolicy: &NativeNetworkPolicy{SchemaVersion: 1}, NativeLearning: true})
	if !strings.Contains(profile, "(allow network-outbound)\n") {
		t.Fatal("trusted learning did not permit observations")
	}
	profile = GenerateSandboxProfile(MacOSSandboxParams{NeedsNetworkRestriction: true, NativePolicy: &NativeNetworkPolicy{SchemaVersion: 1, BestEffort: true}})
	if !strings.Contains(profile, "(allow network-outbound)\n") {
		t.Fatal("explicit best-effort mode not represented")
	}
}
