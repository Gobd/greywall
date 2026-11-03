package sandbox

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTraceHasEvent(t *testing.T) {
	cases := []struct {
		name string
		data string
		want bool
	}{
		{"empty", "", false},
		{"stderr text", "eslogger: Full Disk Access required\n", false},
		{"unrelated json", "{\"ok\":true}\n", false},
		{"invalid pid", "{\"process\":{\"audit_token\":{\"pid\":0}},\"event\":{\"open\":{}}}\n", false},
		{"event", "{\"process\":{\"audit_token\":{\"pid\":42}},\"event\":{\"open\":{}}}\n", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "trace.log")
			if err := os.WriteFile(path, []byte(tc.data), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := traceHasEvent(path); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestTraceStartupRejectsExitedProcess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.log")
	if err := os.WriteFile(path, []byte(`{"process":{"audit_token":{"pid":42}},"event":{"open":{}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	close(done)
	err := waitForTraceStartup(path, done, func() error { return errors.New("permission denied") }, time.Second)
	if err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("expected early exit error, got %v", err)
	}
}

func TestTraceStartupRejectsEmptyOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.log")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	err := waitForTraceStartup(path, make(chan struct{}), func() error { return nil }, 10*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "no valid events") {
		t.Fatalf("expected timeout error, got %v", err)
	}
}

func TestTraceStartupAcceptsLiveEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.log")
	if err := os.WriteFile(path, []byte(`{"process":{"audit_token":{"pid":42}},"event":{"open":{}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := waitForTraceStartup(path, make(chan struct{}), func() error { return nil }, time.Second); err != nil {
		t.Fatal(err)
	}
}
