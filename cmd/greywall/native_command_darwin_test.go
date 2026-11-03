//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GreyhavenHQ/greywall/internal/config"
)

func TestValidateNativeAppRejectsOldOrMissingBeforeLaunch(t *testing.T) {
	app := filepath.Join(t.TempDir(), "Old.app")
	contents := filepath.Join(app, "Contents")
	if err := os.MkdirAll(contents, 0o700); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleVersion</key><string>1</string><key>CFBundleExecutable</key><string>runner</string></dict></plist>`
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(plist), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := validateNativeApp(app); err == nil || !strings.Contains(err.Error(), "build 2+") {
		t.Fatalf("old helper accepted: %v", err)
	}
	if _, err := validateNativeApp(filepath.Join(t.TempDir(), "missing.app")); err == nil {
		t.Fatal("missing helper accepted")
	}
}

func TestNativeRequiresExplicitCredentialOptOut(t *testing.T) {
	previous := noCredentialProtection
	noCredentialProtection = false
	t.Cleanup(func() { noCredentialProtection = previous })
	if err := runNativeCommand(config.Default(), "touch NEVER_EXECUTED", "touch", nil); err == nil || !strings.Contains(err.Error(), "--no-credential-protection") {
		t.Fatalf("missing opt-out accepted: %v", err)
	}
}
