//go:build darwin

package sandbox

import (
	"context"
	"os/exec"
	"testing"
	"time"

	"github.com/GreyhavenHQ/greywall/internal/config"
)

// Syntax check only: the owned child executes true and opens no network sockets.
// This does not install a profile, alter routes or enable a Network Extension.
func TestNativeKernelProfileCompiles(t *testing.T) {
	policy := &NativeNetworkPolicy{SchemaVersion: 1}
	wrapped, err := WrapCommandMacOSNative(config.Default(), "/usr/bin/true", nil, "", false, policy, false)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/bin/sh", "-c", wrapped).CombinedOutput() //nolint:gosec // owned true-only compiler fixture
	if err != nil {
		t.Fatalf("native SBPL did not compile/run true: %v\n%s", err, output)
	}
}
