//go:build windows

package cmd

import (
	"testing"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
)

func TestDisabledStartupNotificationSkipsWindowsSessionWorker(t *testing.T) {
	original := flags
	flags = &pkg_flags.Config{DisableStartupNotification: true}
	t.Cleanup(func() { flags = original })
	// A nil context would fail inside the session worker if it were launched.
	startSecurityWarning(nil)()
}

func TestStartupNotificationDefaultsToDisabled(t *testing.T) {
	flag := RootCmd.PersistentFlags().Lookup("disable-startup-notification")
	if flag == nil || flag.DefValue != "true" {
		t.Fatal("Windows login notifications must be disabled by default in this fork")
	}
	if flag.NoOptDefVal != "true" {
		t.Fatal("bare --disable-startup-notification must disable notifications")
	}
	// An explicit CLI false remains available for users who want notifications.
	previous := flag.Value.String()
	t.Cleanup(func() { _ = flag.Value.Set(previous) })
	if err := flag.Value.Set("false"); err != nil {
		t.Fatal(err)
	}
	if flags.DisableStartupNotification {
		t.Fatal("explicit false must re-enable Windows login notifications")
	}
}
