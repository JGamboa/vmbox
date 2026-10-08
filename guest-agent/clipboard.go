package main

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
)

type Clipboard interface {
	Get() (string, error)
	Set(text string) error
}

type commandClipboard struct{ get, set []string }

// SystemClipboard elige la herramienta del sistema: pbcopy/pbpaste (macOS), wl-clipboard (Wayland) o xclip (X11).
func SystemClipboard() Clipboard {
	switch {
	case runtime.GOOS == "darwin":
		return commandClipboard{get: []string{"pbpaste"}, set: []string{"pbcopy"}}
	case os.Getenv("WAYLAND_DISPLAY") != "":
		return commandClipboard{get: []string{"wl-paste", "--no-newline"}, set: []string{"wl-copy"}}
	default:
		return commandClipboard{get: []string{"xclip", "-selection", "clipboard", "-o"}, set: []string{"xclip", "-selection", "clipboard"}}
	}
}

func (c commandClipboard) Get() (string, error) {
	out, err := exec.Command(c.get[0], c.get[1:]...).Output()
	return string(out), err
}

func (c commandClipboard) Set(text string) error {
	cmd := exec.Command(c.set[0], c.set[1:]...)
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}
