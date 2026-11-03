package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

// commitNativePolicies validates all candidates before replacing any file. The
// caller holds the project lock. Each rename is atomic; rollback restores earlier
// files if a later rename fails. This is not a crash-atomic multi-file transaction.
func commitNativePolicies(updates map[string]string) error {
	return commitNativePoliciesWithRename(updates, os.Rename)
}

func commitNativePoliciesWithRename(updates map[string]string, rename func(string, string) error) error {
	targets := make([]string, 0, len(updates))
	backups := make(map[string]string)
	for target, source := range updates {
		if filepath.Dir(target) != filepath.Dir(source) {
			return fmt.Errorf("policy candidates must be on the destination filesystem")
		}
		info, err := os.Lstat(source)
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("policy candidate is not a regular file: %s", source)
		}
		targets = append(targets, target)
	}
	slices.Sort(targets)
	defer func() {
		for _, backup := range backups {
			_ = os.Remove(backup)
		}
	}()
	for _, target := range targets {
		info, err := os.Lstat(target)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("policy destination is not a regular file: %s", target)
		}
		data, err := os.ReadFile(target) //nolint:gosec // explicit project policy
		if err != nil {
			return err
		}
		backup, err := os.CreateTemp(filepath.Dir(target), ".policy-backup-*")
		if err != nil {
			return err
		}
		backups[target] = backup.Name()
		_, writeErr := backup.Write(data)
		closeErr := backup.Close()
		if err := errors.Join(writeErr, closeErr); err != nil {
			return err
		}
	}
	var applied []string
	for _, target := range targets {
		if err := rename(updates[target], target); err != nil {
			failures := []error{fmt.Errorf("policy commit failed: %w", err)}
			for _, old := range applied {
				if backup := backups[old]; backup != "" {
					failures = append(failures, rename(backup, old))
				} else {
					failures = append(failures, os.Remove(old))
				}
			}
			return errors.Join(failures...)
		}
		applied = append(applied, target)
	}
	return nil
}
