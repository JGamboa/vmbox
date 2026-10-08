package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeClipboard struct{ text string }

func (f *fakeClipboard) Get() (string, error)   { return f.text, nil }
func (f *fakeClipboard) Set(text string) error { f.text = text; return nil }

func testHandler() *Handler {
	return &Handler{Shell: []string{"/bin/sh", "-c"}, RootPrefix: []string{"env", "VMBOX_ROOT=1"}, Clipboard: &fakeClipboard{}}
}

func call(t *testing.T, h *Handler, method string, params any) (map[string]any, *RPCError) {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	result, rpcErr := h.Dispatch(method, raw)
	if rpcErr != nil {
		return nil, rpcErr
	}
	return result.(map[string]any), nil
}

func TestRunCommandCapturesOutputAndExitCode(t *testing.T) {
	r, err := call(t, testHandler(), "run_command", map[string]any{"command": "echo hola; echo error >&2; exit 3"})
	if err != nil {
		t.Fatal(err)
	}
	if r["stdout"] != "hola\n" || r["stderr"] != "error\n" || r["exit_code"] != 3 || r["timed_out"] != false {
		t.Fatalf("resultado inesperado: %#v", r)
	}
}

func TestRunCommandIgnoresExtraParamsLikeVM(t *testing.T) {
	if _, err := call(t, testHandler(), "run_command", map[string]any{"vm": "Ubuntu", "command": "true"}); err != nil {
		t.Fatal(err)
	}
}

func TestRunCommandTimeout(t *testing.T) {
	start := time.Now()
	r, err := call(t, testHandler(), "run_command", map[string]any{"command": "sleep 5", "timeout_s": 0.3})
	if err != nil {
		t.Fatal(err)
	}
	if r["timed_out"] != true || r["exit_code"] != -1 {
		t.Fatalf("se esperaba timeout: %#v", r)
	}
	if time.Since(start) > 4*time.Second {
		t.Fatalf("el timeout no cortó el comando a tiempo: %v", time.Since(start))
	}
}

func TestRunCommandAsRootUsesPrefix(t *testing.T) {
	r, _ := call(t, testHandler(), "run_command", map[string]any{"command": "echo $VMBOX_ROOT", "as_root": true})
	if r["stdout"] != "1\n" {
		t.Fatalf("as_root no usó el prefijo: %#v", r)
	}
}

func TestRunCommandTruncatesLargeOutput(t *testing.T) {
	r, _ := call(t, testHandler(), "run_command", map[string]any{"command": "head -c 2000000 /dev/zero | tr '\\0' a"})
	if r["truncated"] != true || len(r["stdout"].(string)) != maxOutputBytes {
		t.Fatalf("no truncó: truncated=%v len=%d", r["truncated"], len(r["stdout"].(string)))
	}
}

func TestRunCommandRequiresCommand(t *testing.T) {
	if _, err := call(t, testHandler(), "run_command", map[string]any{}); err == nil || err.Data != "invalid_argument" {
		t.Fatalf("se esperaba invalid_argument, obtuve %#v", err)
	}
}

func TestWriteThenReadTextFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nota.txt")
	h := testHandler()
	if _, err := call(t, h, "write_file", map[string]any{"path": path, "content": "hola ñandú"}); err != nil {
		t.Fatal(err)
	}
	r, err := call(t, h, "read_file", map[string]any{"path": path})
	if err != nil {
		t.Fatal(err)
	}
	if r["content"] != "hola ñandú" || r["encoding"] != "utf8" {
		t.Fatalf("lectura inesperada: %#v", r)
	}
}

func TestBinaryFileIsBase64(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bin")
	if err := os.WriteFile(path, []byte{0xff, 0x00, 0xfe}, 0o644); err != nil {
		t.Fatal(err)
	}
	r, _ := call(t, testHandler(), "read_file", map[string]any{"path": path})
	if r["encoding"] != "base64" || r["content"] != "/wD+" {
		t.Fatalf("binario mal codificado: %#v", r)
	}
	if _, err := call(t, testHandler(), "write_file", map[string]any{"path": path, "content": "AAE=", "encoding": "base64"}); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "\x00\x01" {
		t.Fatalf("write_file base64 incorrecto: %v", data)
	}
}

func TestFilePathRules(t *testing.T) {
	h := testHandler()
	for _, tc := range []struct {
		method string
		params map[string]any
	}{
		{"read_file", map[string]any{"path": "relativa.txt"}},
		{"read_file", map[string]any{"path": "/no/existe"}},
		{"read_file", map[string]any{"path": t.TempDir()}},
		{"write_file", map[string]any{"path": "relativa.txt", "content": "x"}},
		{"write_file", map[string]any{"path": "/no/existe/dir/x.txt", "content": "x"}},
	} {
		if _, err := call(t, h, tc.method, tc.params); err == nil || err.Data != "invalid_argument" {
			t.Errorf("%s %v: se esperaba invalid_argument, obtuve %#v", tc.method, tc.params, err)
		}
	}
}

func TestReadFileTooLarge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "grande")
	if err := os.WriteFile(path, make([]byte, maxFileBytes+1), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := call(t, testHandler(), "read_file", map[string]any{"path": path})
	if err == nil || !strings.Contains(err.Message, "10 MB") {
		t.Fatalf("se esperaba error de tamaño, obtuve %#v", err)
	}
}

func TestClipboard(t *testing.T) {
	h := testHandler()
	if _, err := call(t, h, "clipboard_set", map[string]any{"text": "copiado"}); err != nil {
		t.Fatal(err)
	}
	r, _ := call(t, h, "clipboard_get", map[string]any{})
	if r["text"] != "copiado" {
		t.Fatalf("portapapeles: %#v", r)
	}
}

func TestUnknownMethod(t *testing.T) {
	if _, err := call(t, testHandler(), "format_disk", map[string]any{}); err == nil || err.Data != "invalid_argument" {
		t.Fatalf("se esperaba invalid_argument: %#v", err)
	}
}

func TestRunCommandWithBackgroundChildReturnsOutput(t *testing.T) {
	start := time.Now()
	r, err := call(t, testHandler(), "run_command", map[string]any{"command": "sleep 30 & echo ok"})
	if err != nil {
		t.Fatal(err)
	}
	if r["stdout"] != "ok\n" || r["exit_code"] != 0 || r["timed_out"] != false {
		t.Fatalf("resultado inesperado: %#v", r)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("tardó demasiado: %v", time.Since(start))
	}
}
