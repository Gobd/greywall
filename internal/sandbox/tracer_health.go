package sandbox

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// waitForTraceStartup requires an actual event, not just a successfully spawned
// sudo process. stderr messages and empty/malformed output are not a ready trace.
func waitForTraceStartup(path string, done <-chan struct{}, exitErr func() error, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return fmt.Errorf("filesystem tracer exited during startup: %v; check sudo and macOS Full Disk Access for your terminal", exitErr())
		default:
		}
		if traceHasEvent(path) {
			select {
			case <-done:
				return fmt.Errorf("filesystem tracer exited during startup: %v", exitErr())
			default:
				return nil
			}
		}
		select {
		case <-done:
			return fmt.Errorf("filesystem tracer exited during startup: %v; check sudo and macOS Full Disk Access for your terminal", exitErr())
		case <-timer.C:
			return fmt.Errorf("filesystem tracer produced no valid events within %s; refusing to learn an empty profile; check macOS Full Disk Access for your terminal", timeout)
		case <-ticker.C:
		}
	}
}

func traceHasEvent(path string) bool {
	file, err := os.Open(path) //nolint:gosec // manager-owned trace path
	if err != nil {
		return false
	}
	defer func() { _ = file.Close() }()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var event struct {
			Process struct {
				AuditToken struct {
					PID int `json:"pid"`
				} `json:"audit_token"`
			} `json:"process"`
			Event map[string]json.RawMessage `json:"event"`
		}
		if json.Unmarshal(scanner.Bytes(), &event) == nil && event.Process.AuditToken.PID > 0 && len(event.Event) > 0 {
			return true
		}
	}
	return false
}
