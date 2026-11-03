//go:build darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"github.com/GreyhavenHQ/greywall/internal/config"
	"github.com/GreyhavenHQ/greywall/internal/sandbox"
	"golang.org/x/sys/unix"
)

// Native is opt-in. No helper installation/activation, credential substitution
// or broad enforcing egress fallback happens here. An old helper fails before
// any target command is launched or tracer is started.
func runNativeCommand(cfg *config.Config, command, cmdName string, ports []int) error {
	if runtime.GOARCH != "arm64" {
		return fmt.Errorf("native helper requires Apple Silicon macOS")
	}
	if !noCredentialProtection || len(injectLabels) != 0 || len(secretVars) != 0 || len(cfg.Credentials.Inject) != 0 || len(cfg.Credentials.Secrets) != 0 {
		return fmt.Errorf("native backend does not support proxy credential substitution; explicitly use --no-credential-protection and remove --inject/--secret options")
	}
	if watch || profileName != "" || autoProfile || len(forwardPorts) != 0 || len(allowDests) != 0 || proxyURL != "" || httpProxyURL != "" || dnsAddr != "" || proxyUserFlag != "" || noNetworkRules {
		return fmt.Errorf("native backend uses project policies, not proxy/watch/profile/forward/--allow options; use --settings for explicit filesystem configuration")
	}
	app, err := validateNativeApp(nativeAppPath)
	if err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	project := nativeProjectRoot
	if project == "" {
		project = cwd
	}
	project, err = filepath.Abs(project)
	if err != nil {
		return err
	}
	project, err = filepath.EvalSymlinks(project)
	if err != nil {
		return fmt.Errorf("native project root: %w", err)
	}
	policyDir := filepath.Join(project, ".greywall")
	if info, statErr := os.Lstat(policyDir); statErr == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("project .greywall must be a real directory, not a symlink")
		}
	} else if !os.IsNotExist(statErr) {
		return statErr
	}
	if err := os.MkdirAll(policyDir, 0o700); err != nil {
		return err
	}
	lockPath := filepath.Join(policyDir, "session.lock")
	fd, err := unix.Open(lockPath, unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = unix.Close(fd) }()
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return fmt.Errorf("another Greywall command is managing this project's policy: %w", err)
	}
	defer func() { _ = unix.Flock(fd, unix.LOCK_UN) }()

	networkPath := filepath.Join(policyDir, "network.json")
	policy, err := sandbox.LoadNativeNetworkPolicy(networkPath)
	if err != nil {
		return err
	}
	policy.BestEffort = nativeBestEffort
	filesystemPath := filepath.Join(policyDir, "filesystem.json")
	if info, statErr := os.Lstat(filesystemPath); statErr == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("filesystem policy must be a regular file")
		}
		profile, loadErr := config.Load(filesystemPath)
		if loadErr != nil {
			return loadErr
		}
		if profile != nil {
			cfg = config.Merge(cfg, profile)
		}
	} else if !os.IsNotExist(statErr) {
		return statErr
	}
	for _, path := range allowPaths {
		cfg.Filesystem.AllowRead = append(cfg.Filesystem.AllowRead, path)
		cfg.Filesystem.AllowWrite = append(cfg.Filesystem.AllowWrite, path)
	}
	cfg.Filesystem.AllowRead = append(cfg.Filesystem.AllowRead, allowReadPaths...)
	// Child code cannot rewrite policy/control state. The signed supervisor is
	// outside the child's inherited Seatbelt profile and writes candidates only.
	cfg.Filesystem.DenyWrite = append(cfg.Filesystem.DenyWrite, policyDir)
	if home, homeErr := os.UserHomeDir(); homeErr == nil {
		state := filepath.Join(home, "Library", "Application Support", "GreywallNative")
		cfg.Filesystem.DenyRead = append(cfg.Filesystem.DenyRead, state)
		cfg.Filesystem.DenyWrite = append(cfg.Filesystem.DenyWrite, state)
	}
	netLearning := learning || nativeLearnNetwork
	manager := sandbox.NewManager(cfg, debug, monitor)
	defer manager.Cleanup()
	manager.SetExposedPorts(ports)
	manager.SetLearning(learning)
	manager.SetCommandName(cmdName)
	if err := manager.SetNativeNetwork(policy, netLearning); err != nil {
		return err
	}
	if err := sandbox.CheckCommand(command, cfg); err != nil {
		return err
	}

	var networkCandidate, filesystemCandidate string
	if netLearning {
		networkCandidate, err = nativeCandidate(policyDir, "network")
		if err != nil {
			return err
		}
		defer func() { _ = os.Remove(networkCandidate) }()
	}
	if learning {
		filesystemCandidate, err = nativeCandidate(policyDir, "filesystem")
		if err != nil {
			return err
		}
		defer func() { _ = os.Remove(filesystemCandidate) }()
		manager.SetLearningOutputPath(filesystemCandidate)
	}
	if err := manager.Initialize(); err != nil {
		return err
	}
	wrapped, err := manager.WrapCommand(command)
	if err != nil {
		return err
	}
	mode := "enforce"
	if netLearning {
		mode = "learn"
	}
	arguments := []string{"--native-launch", "--mode", mode, "--policy", networkPath, "--cwd", cwd}
	if networkCandidate != "" {
		arguments = append(arguments, "--export", networkCandidate)
	}
	arguments = append(arguments, "--", "/bin/sh", "-c", wrapped)
	fmt.Fprintf(os.Stderr, "[greywall:native] EXPERIMENTAL: helper IP/TCP/UDP rules are process-attribution based, not descendant-safe kernel rules. Shared DNS is permitted. Policy: %s\n", networkPath)
	child := exec.Command(app, arguments...) //nolint:gosec // validated app + intentional user command wrapper
	child.Env = sandbox.GetHardenedEnv()
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := child.Start(); err != nil {
		return fmt.Errorf("native supervisor launch failed: %w", err)
	}
	manager.SetLearningRootPID(child.Process.Pid)
	signals := make(chan os.Signal, 8)
	done := make(chan struct{})
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGWINCH)
	defer signal.Stop(signals)
	go func() {
		for {
			select {
			case sig := <-signals:
				_ = child.Process.Signal(sig)
			case <-done:
				return
			}
		}
	}()
	waitErr := child.Wait()
	close(done)
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			exitCode = exitErr.ExitCode()
			return nil // no candidate commit on failure
		}
		return waitErr
	}
	if learning {
		if _, err := manager.GenerateLearnedTemplate(cmdName); err != nil {
			return fmt.Errorf("filesystem learning failed; previous project policies retained: %w", err)
		}
	}
	if netLearning {
		if _, err := sandbox.LoadNativeNetworkPolicy(networkCandidate); err != nil {
			return fmt.Errorf("invalid network learning candidate; previous policies retained: %w", err)
		}
		updates := map[string]string{networkPath: networkCandidate}
		if learning {
			updates[filesystemPath] = filesystemCandidate
		}
		if err := commitNativePolicies(updates); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "[greywall:native] Project learning saved. Review %s before enforcement.\n", policyDir)
	}
	return nil
}

func validateNativeApp(directory string) (string, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	infoPath := filepath.Join(absolute, "Contents", "Info.plist")
	versionBytes, err := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print CFBundleVersion", infoPath).Output() //nolint:gosec // fixed utility reads explicitly selected app metadata
	if err != nil {
		return "", fmt.Errorf("native app unavailable; build/install the helper explicitly first: %w", err)
	}
	build, err := strconv.Atoi(strings.TrimSpace(string(versionBytes)))
	if err != nil || build < 2 {
		return "", fmt.Errorf("native app requires build 2+ with readiness channel; target command not launched")
	}
	executableBytes, err := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print CFBundleExecutable", infoPath).Output() //nolint:gosec // fixed utility reads explicitly selected app metadata
	if err != nil {
		return "", err
	}
	name := strings.TrimSpace(string(executableBytes))
	if name == "" || filepath.Base(name) != name {
		return "", fmt.Errorf("invalid native app executable name")
	}
	if err := exec.Command("/usr/bin/codesign", "--verify", "--deep", "--strict", absolute).Run(); err != nil { //nolint:gosec // verification only of an explicit app path
		return "", fmt.Errorf("native app signature verification failed: %w", err)
	}
	return filepath.Join(absolute, "Contents", "MacOS", name), nil
}

func nativeCandidate(directory, kind string) (string, error) {
	file, err := os.CreateTemp(directory, "learn-"+kind+"-*.json")
	if err != nil {
		return "", err
	}
	path := file.Name()
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", err
	}
	return path, nil
}
