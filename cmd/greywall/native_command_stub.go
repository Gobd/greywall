//go:build !darwin

package main

import (
	"fmt"

	"github.com/GreyhavenHQ/greywall/internal/config"
)

func runNativeCommand(_ *config.Config, _, _ string, _ []int) error {
	return fmt.Errorf("--experimental-native-network is Apple Silicon macOS only; Linux uses its existing namespace/TUN/proxy backend; no command launched")
}
