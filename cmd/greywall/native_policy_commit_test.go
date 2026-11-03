package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestNativePolicyCommitAndRollback(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(map[bool]string{false: "commit", true: "rollback"}[failure], func(t *testing.T) {
			directory := t.TempDir()
			updates := make(map[string]string)
			for _, name := range []string{"a", "b"} {
				target := filepath.Join(directory, name+".json")
				candidate := target + ".candidate"
				for path, value := range map[string]string{target: "old-" + name, candidate: "new-" + name} {
					if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				updates[target] = candidate
			}
			calls := 0
			rename := func(source, target string) error {
				calls++
				if failure && calls == 2 {
					return errors.New("injected commit failure")
				}
				return os.Rename(source, target)
			}
			err := commitNativePoliciesWithRename(updates, rename)
			if (err != nil) != failure {
				t.Fatalf("error=%v, failure=%v", err, failure)
			}
			for target := range updates {
				data, err := os.ReadFile(target) //nolint:gosec // test-owned temp file
				if err != nil {
					t.Fatal(err)
				}
				prefix := "new-"
				if failure {
					prefix = "old-"
				}
				want := prefix + filepath.Base(target)[:1]
				if string(data) != want {
					t.Errorf("%s = %s, want %s", target, data, want)
				}
			}
		})
	}
}

func TestNativePolicyCommitValidatesAllCandidatesFirst(t *testing.T) {
	directory := t.TempDir()
	target := filepath.Join(directory, "a.json")
	candidate := target + ".candidate"
	if err := os.WriteFile(target, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(candidate, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := commitNativePolicies(map[string]string{target: candidate, filepath.Join(directory, "b.json"): filepath.Join(directory, "missing")})
	if err == nil {
		t.Fatal("invalid candidate accepted")
	}
	data, err := os.ReadFile(target) //nolint:gosec // test-owned temp file
	if err != nil || string(data) != "old" {
		t.Fatalf("previous policy changed: %s, %v", data, err)
	}
}
