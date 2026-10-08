# VMBox — Fase 4: guest-agent vía vsock (comandos, archivos, portapapeles)

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`). Lee primero el índice [2026-10-08-vmbox-mvp-00-indice.md](2026-10-08-vmbox-mvp-00-indice.md). **Requisito:** Fase 3 terminada (el instalador se comparte por VirtioFS).

**Objetivo:** un binario `vmbox-guest-agent` dentro del invitado (Ubuntu y macOS) que, por vsock, ejecuta comandos, lee/escribe archivos y usa el portapapeles; expuesto en MCP como `run_command`, `read_file`, `write_file`, `clipboard_get`, `clipboard_set`.

**Arquitectura:**
```
vmbox-mcp ──socket──▶ VMBox (ControlService) ──GuestAgentClient──▶ VZVirtioSocketDevice.connect(7000)
                                                                       │ vsock, JSON-RPC por líneas (mismo formato que control.sock)
                                                                       ▼
                                                     vmbox-guest-agent (Go) en el invitado
```
El guest-agent es Go (compila cruzado a `linux/arm64` y `darwin/arm64` sin toolchains extra). El host reutiliza `RPC.exchange` y `LineChannel` sobre el descriptor de la conexión vsock. El instalador (binarios + scripts) va dentro de `VMBox.app/Contents/Resources/GuestTools` y se comparte con la VM como carpeta de solo lectura.

**Stack:** Go 1.27 + `golang.org/x/sys/unix` (AF_VSOCK), Swift 6.3, Virtualization.framework (`VZVirtioSocketDevice`), systemd (usuario) en Ubuntu, launchd en macOS.

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md) §3.2 (`VZVirtioSocketDevice`), §5.3, §5.4, §6, §8 punto 4.

## Estructura de archivos de esta fase

```
guest-agent/
  go.mod, go.sum
  protocol.go      Request/Response/RPCError (mismo JSON que ControlProtocol)
  handlers.go      run_command, read_file, write_file, clipboard_*, ping
  clipboard.go     pbcopy/pbpaste, wl-copy/wl-paste, xclip
  serve.go         bucle de líneas sobre un io.ReadWriter
  vsock.go         escucha AF_VSOCK (linux || darwin)
  main.go          flags -port, -stdio
  handlers_test.go, serve_test.go
  install/install-linux.sh, install-macos.sh, vmbox-guest-agent.service, cl.multiapi.vmbox.guest-agent.plist
scripts/build-guest-agent.sh            → guest-agent/dist/GuestTools/{linux-arm64,darwin-arm64}/…
Packages/VMCore/Sources/ControlProtocol/GuestAgentClient.swift (+ código guest_agent_unavailable en Messages.swift)
Packages/VMCore/Tests/ControlProtocolTests/GuestAgentClientTests.swift
Packages/VMCore/Sources/AgentControl/ (VMControlling.guestCall, ControlService) · Sources/MCPBridge/ToolCatalog.swift
VMBox/Control/VsockGuestConnector.swift · VMBox/Model/AgentVMAdapter.swift · VMBox/Views/VMSettingsSheet.swift · project.yml · scripts/build.sh · scripts/test.sh
```

---

### Tarea 4.1: guest-agent — protocolo, manejadores y servidor por líneas

**Archivos:**
- Crear: `guest-agent/go.mod`, `guest-agent/protocol.go`, `guest-agent/handlers.go`, `guest-agent/clipboard.go`, `guest-agent/serve.go`, `guest-agent/main.go`, `guest-agent/vsock.go`, `guest-agent/handlers_test.go`, `guest-agent/serve_test.go`
- Modificar: `scripts/test.sh`

**Interfaces:**
- Produce (protocolo en el cable, idéntico a `ControlRequest/ControlResponse`): petición `{"jsonrpc":"2.0","id":N,"method":M,"params":{…}}`; respuesta `{"jsonrpc":"2.0","id":N,"result":{…}}` o `{"jsonrpc":"2.0","id":N,"error":{"code":-32000,"message":…,"data":"invalid_argument"|"internal_error"}}`.
- Métodos: `ping` → `{version, os}`; `run_command {command, timeout_s?=60, as_root?}` → `{stdout, stderr, exit_code, timed_out, truncated}` (salidas ≤1 MiB c/u, `as_root` usa `sudo -n`); `read_file {path}` → `{content, encoding: "utf8"|"base64", size}` (ruta absoluta, ≤10 MiB); `write_file {path, content, encoding?}` → `{bytes_written}`; `clipboard_get` → `{text}`; `clipboard_set {text}` → `{ok}`.
- Go: `NewHandler()`, `(*Handler).Dispatch(method, params) (any, *RPCError)`, `Serve(io.ReadWriter, *Handler) error`, `ListenVsock(port uint32, handle func(*os.File)) error`.

- [ ] **Paso 1: módulo**

`guest-agent/go.mod`:

```
module vmbox/guest-agent

go 1.23
```

Run: `cd guest-agent && go get golang.org/x/sys@latest && cd ..`
Expected: `go.mod` gana `require golang.org/x/sys vX.Y.Z` y aparece `go.sum`.

- [ ] **Paso 2: tests que fallan**

`guest-agent/handlers_test.go`:

```go
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
```

`guest-agent/serve_test.go`:

```go
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

type pipeRW struct {
	io.Reader
	io.Writer
}

func TestServeAnswersEachLineWithSameShapeAsControlProtocol(t *testing.T) {
	input := strings.NewReader(
		`{"jsonrpc":"2.0","id":7,"method":"ping","params":{}}` + "\n" +
			"esto no es json\n" +
			`{"jsonrpc":"2.0","id":8,"method":"nada","params":{}}` + "\n")
	var output bytes.Buffer
	if err := Serve(pipeRW{input, &output}, testHandler()); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(&output)
	var lines []map[string]any
	for scanner.Scan() {
		var m map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &m); err != nil {
			t.Fatalf("línea no JSON: %s", scanner.Text())
		}
		lines = append(lines, m)
	}
	if len(lines) != 3 {
		t.Fatalf("se esperaban 3 respuestas, hubo %d", len(lines))
	}
	if lines[0]["jsonrpc"] != "2.0" || lines[0]["id"] != float64(7) || lines[0]["result"].(map[string]any)["version"] != version {
		t.Fatalf("ping: %#v", lines[0])
	}
	for _, i := range []int{1, 2} {
		e := lines[i]["error"].(map[string]any)
		if e["code"] != float64(-32000) || e["data"] != "invalid_argument" {
			t.Fatalf("error %d con forma inesperada: %#v", i, lines[i])
		}
	}
	if _, has := lines[2]["result"]; has {
		t.Fatalf("una respuesta de error no debe traer result: %#v", lines[2])
	}
}
```

- [ ] **Paso 3: verificar que falla**

Run: `cd guest-agent && go test ./... ; cd ..`
Expected: FAIL de compilación (`undefined: Handler`)

- [ ] **Paso 4: implementación**

`guest-agent/protocol.go`:

```go
package main

import "encoding/json"

// Mismo formato que ControlRequest/ControlResponse del host (JSON-RPC 2.0, una línea por mensaje).
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int64           `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    string `json:"data"` // código legible: invalid_argument | internal_error
}

type Response struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      int64     `json:"id"`
	Result  any       `json:"result,omitempty"`
	Error   *RPCError `json:"error,omitempty"`
}

func invalidArgument(message string) *RPCError {
	return &RPCError{Code: -32000, Message: message, Data: "invalid_argument"}
}

func internalError(message string) *RPCError {
	return &RPCError{Code: -32000, Message: message, Data: "internal_error"}
}
```

`guest-agent/handlers.go`:

```go
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	version        = "0.1.0"
	maxOutputBytes = 1 << 20
	maxFileBytes   = 10 << 20
	maxTimeout     = time.Hour
)

type Handler struct {
	Shell      []string // p. ej. ["/bin/sh", "-c"]
	RootPrefix []string // p. ej. ["sudo", "-n"]
	Clipboard  Clipboard
}

func NewHandler() *Handler {
	return &Handler{Shell: []string{"/bin/sh", "-c"}, RootPrefix: []string{"sudo", "-n"}, Clipboard: SystemClipboard()}
}

func (h *Handler) Dispatch(method string, params json.RawMessage) (any, *RPCError) {
	switch method {
	case "ping":
		return map[string]any{"version": version, "os": runtime.GOOS}, nil
	case "run_command":
		var p struct {
			Command  string   `json:"command"`
			TimeoutS *float64 `json:"timeout_s"`
			AsRoot   bool     `json:"as_root"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		timeout := 60 * time.Second
		if p.TimeoutS != nil {
			if *p.TimeoutS <= 0 {
				return nil, invalidArgument("timeout_s debe ser mayor que 0")
			}
			timeout = min(time.Duration(*p.TimeoutS*float64(time.Second)), maxTimeout)
		}
		return h.runCommand(p.Command, timeout, p.AsRoot)
	case "read_file":
		var p struct {
			Path string `json:"path"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return readFile(p.Path)
	case "write_file":
		var p struct {
			Path     string `json:"path"`
			Content  string `json:"content"`
			Encoding string `json:"encoding"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return writeFile(p.Path, p.Content, p.Encoding)
	case "clipboard_get":
		text, err := h.Clipboard.Get()
		if err != nil {
			return nil, internalError("no se pudo leer el portapapeles: " + err.Error())
		}
		return map[string]any{"text": text}, nil
	case "clipboard_set":
		var p struct {
			Text *string `json:"text"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		if p.Text == nil {
			return nil, invalidArgument("falta el parámetro «text»")
		}
		if err := h.Clipboard.Set(*p.Text); err != nil {
			return nil, internalError("no se pudo escribir el portapapeles: " + err.Error())
		}
		return map[string]any{"ok": true}, nil
	default:
		return nil, invalidArgument("método desconocido: " + method)
	}
}

func decode(params json.RawMessage, v any) *RPCError {
	if len(params) == 0 {
		params = []byte("{}")
	}
	if err := json.Unmarshal(params, v); err != nil {
		return invalidArgument("parámetros inválidos: " + err.Error())
	}
	return nil
}

func (h *Handler) runCommand(command string, timeout time.Duration, asRoot bool) (any, *RPCError) {
	if strings.TrimSpace(command) == "" {
		return nil, invalidArgument("falta el parámetro «command»")
	}
	args := append(append([]string{}, h.Shell...), command)
	if asRoot {
		args = append(append([]string{}, h.RootPrefix...), args...)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	// Grupo de procesos propio para matar también a los hijos del shell al vencer el timeout.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	var stdout, stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	err := cmd.Run()
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	exitCode := 0
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		exitCode = exitErr.ExitCode()
	case timedOut:
	default:
		return nil, internalError("no se pudo ejecutar el comando: " + err.Error())
	}
	if timedOut {
		exitCode = -1
	}
	return map[string]any{
		"stdout": stdout.String(), "stderr": stderr.String(), "exit_code": exitCode,
		"timed_out": timedOut, "truncated": stdout.truncated || stderr.truncated,
	}, nil
}

// limitedBuffer guarda hasta maxOutputBytes y descarta el resto.
type limitedBuffer struct {
	buf       bytes.Buffer
	truncated bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	room := maxOutputBytes - b.buf.Len()
	if len(p) > room {
		b.truncated = true
		if room > 0 {
			b.buf.Write(p[:room])
		}
		return len(p), nil
	}
	return b.buf.Write(p)
}

func (b *limitedBuffer) String() string { return strings.ToValidUTF8(b.buf.String(), "�") }

func readFile(path string) (any, *RPCError) {
	if !filepath.IsAbs(path) {
		return nil, invalidArgument("path debe ser absoluta: " + path)
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, invalidArgument(err.Error())
	}
	if info.IsDir() {
		return nil, invalidArgument(path + " es un directorio")
	}
	if info.Size() > maxFileBytes {
		return nil, invalidArgument(fmt.Sprintf("%s ocupa %d bytes; el máximo es 10 MB", path, info.Size()))
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, invalidArgument(err.Error())
	}
	if utf8.Valid(data) {
		return map[string]any{"content": string(data), "encoding": "utf8", "size": len(data)}, nil
	}
	return map[string]any{"content": base64.StdEncoding.EncodeToString(data), "encoding": "base64", "size": len(data)}, nil
}

func writeFile(path, content, encoding string) (any, *RPCError) {
	if !filepath.IsAbs(path) {
		return nil, invalidArgument("path debe ser absoluta: " + path)
	}
	data := []byte(content)
	switch encoding {
	case "", "utf8":
	case "base64":
		decoded, err := base64.StdEncoding.DecodeString(content)
		if err != nil {
			return nil, invalidArgument("content no es base64 válido")
		}
		data = decoded
	default:
		return nil, invalidArgument("encoding debe ser utf8 o base64")
	}
	if len(data) > maxFileBytes {
		return nil, invalidArgument("el contenido supera 10 MB")
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return nil, invalidArgument(err.Error())
	}
	return map[string]any{"bytes_written": len(data)}, nil
}
```

`guest-agent/clipboard.go`:

```go
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
```

`guest-agent/serve.go`:

```go
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

// Serve atiende peticiones JSON-RPC, una por línea, hasta EOF.
func Serve(rw io.ReadWriter, h *Handler) error {
	reader := bufio.NewReaderSize(rw, 64*1024)
	encoder := json.NewEncoder(rw)
	encoder.SetEscapeHTML(false)
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			response := Response{JSONRPC: "2.0"}
			var request Request
			if err := json.Unmarshal(line, &request); err != nil {
				response.Error = invalidArgument("mensaje JSON-RPC inválido")
			} else {
				response.ID = request.ID
				response.Result, response.Error = h.Dispatch(request.Method, request.Params)
			}
			if err := encoder.Encode(response); err != nil {
				return err
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
}
```

`guest-agent/vsock.go`:

```go
//go:build linux || darwin

package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// ListenVsock escucha en el puerto vsock indicado (cualquier CID) y atiende cada conexión en una goroutine.
func ListenVsock(port uint32, handle func(*os.File)) error {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return fmt.Errorf("socket AF_VSOCK: %w", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		unix.Close(fd)
		return fmt.Errorf("bind vsock:%d: %w", port, err)
	}
	if err := unix.Listen(fd, 16); err != nil {
		unix.Close(fd)
		return fmt.Errorf("listen vsock:%d: %w", port, err)
	}
	for {
		conn, _, err := unix.Accept(fd)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return fmt.Errorf("accept: %w", err)
		}
		go handle(os.NewFile(uintptr(conn), "vsock"))
	}
}
```

`guest-agent/main.go`:

```go
package main

import (
	"flag"
	"log"
	"os"
)

type stdio struct{}

func (stdio) Read(p []byte) (int, error)  { return os.Stdin.Read(p) }
func (stdio) Write(p []byte) (int, error) { return os.Stdout.Write(p) }

func main() {
	port := flag.Uint("port", 7000, "puerto vsock")
	useStdio := flag.Bool("stdio", false, "atender una sesión por stdin/stdout (pruebas)")
	flag.Parse()
	h := NewHandler()
	if *useStdio {
		if err := Serve(stdio{}, h); err != nil {
			log.Fatal(err)
		}
		return
	}
	log.Printf("vmbox-guest-agent %s escuchando en vsock:%d", version, *port)
	log.Fatal(ListenVsock(uint32(*port), func(conn *os.File) {
		defer conn.Close()
		if err := Serve(conn, h); err != nil {
			log.Printf("conexión: %v", err)
		}
	}))
}
```

- [ ] **Paso 5: verificar que pasa**

Run: `cd guest-agent && go vet ./... && go test ./... ; cd ..`
Expected: `ok  vmbox/guest-agent`

- [ ] **Paso 6: tests de Go en `scripts/test.sh`**

Añade al final de `scripts/test.sh`:

```bash
(cd guest-agent && go test ./...)
```

Run: `scripts/test.sh`
Expected: tests de Swift y Go en verde.

- [ ] **Paso 7: commit**

```bash
git add guest-agent scripts/test.sh
git commit -m "feat(guest-agent): comandos, archivos y portapapeles por JSON-RPC"
```

---

### Tarea 4.2: Compilación cruzada, instaladores y prueba de vsock en ambos invitados

**Archivos:**
- Crear: `scripts/build-guest-agent.sh`, `guest-agent/install/install-linux.sh`, `guest-agent/install/install-macos.sh`, `guest-agent/install/vmbox-guest-agent.service`, `guest-agent/install/cl.multiapi.vmbox.guest-agent.plist`
- Modificar: `scripts/build.sh`

**Interfaces:**
- Produce: `guest-agent/dist/GuestTools/` con `linux-arm64/vmbox-guest-agent`, `darwin-arm64/vmbox-guest-agent` y los scripts de instalación; la Tarea 4.5 lo empaqueta en `VMBox.app/Contents/Resources/GuestTools`.

- [ ] **Paso 1: script de compilación**

`scripts/build-guest-agent.sh`:

```bash
#!/bin/bash
# Compila vmbox-guest-agent para Ubuntu (linux/arm64) y macOS (darwin/arm64) y arma GuestTools/.
set -euo pipefail
cd "$(dirname "$0")/../guest-agent"
export PATH="/opt/homebrew/bin:$PATH"
OUT=dist/GuestTools
rm -rf dist
mkdir -p "$OUT/linux-arm64" "$OUT/darwin-arm64"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$OUT/linux-arm64/vmbox-guest-agent" .
# El linker de Go firma ad hoc los binarios darwin/arm64 (obligatorio en Apple silicon).
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$OUT/darwin-arm64/vmbox-guest-agent" .
cp install/* "$OUT/"
chmod +x "$OUT"/*.sh
echo "OK: guest-agent/$OUT"
```

En `scripts/build.sh`, antes de `xcodegen generate --quiet`, añade:

```bash
scripts/build-guest-agent.sh
```

Run: `chmod +x scripts/build-guest-agent.sh && scripts/build-guest-agent.sh && file guest-agent/dist/GuestTools/*/vmbox-guest-agent`
Expected: `ELF 64-bit LSB executable, ARM aarch64` y `Mach-O 64-bit executable arm64`.

- [ ] **Paso 2: instalador para Ubuntu**

`guest-agent/install/vmbox-guest-agent.service`:

```ini
[Unit]
Description=VMBox guest agent (vsock 7000)
After=graphical-session.target

[Service]
ExecStart=/usr/local/bin/vmbox-guest-agent -port 7000
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

`guest-agent/install/install-linux.sh`:

```bash
#!/bin/bash
# Instala vmbox-guest-agent en Ubuntu arm64 como servicio de usuario (necesita la sesión gráfica para el portapapeles).
# Uso, desde la cuenta del usuario de escritorio: sudo /mnt/vmbox/GuestTools/install-linux.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta con sudo"; exit 1; }
USER_NAME="${SUDO_USER:?Ejecuta con sudo desde tu usuario de escritorio}"
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "$HERE/linux-arm64/vmbox-guest-agent" /usr/local/bin/vmbox-guest-agent
apt-get install -y wl-clipboard xclip >/dev/null 2>&1 || echo "Aviso: no se pudo instalar wl-clipboard/xclip; el portapapeles no funcionará."
install -m 0644 "$HERE/vmbox-guest-agent.service" /etc/systemd/user/vmbox-guest-agent.service
systemctl --global enable vmbox-guest-agent.service

# run_command con as_root usa «sudo -n»: sudo sin contraseña para este usuario.
# La VM es un entorno desechable para el agente; no instales esto en máquinas que no lo sean.
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vmbox-guest-agent
chmod 0440 /etc/sudoers.d/vmbox-guest-agent
visudo -cf /etc/sudoers.d/vmbox-guest-agent

USER_ID=$(id -u "$USER_NAME")
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user restart vmbox-guest-agent.service
echo "vmbox-guest-agent instalado y en marcha (vsock:7000)."
```

- [ ] **Paso 3: instalador para macOS**

`guest-agent/install/cl.multiapi.vmbox.guest-agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>cl.multiapi.vmbox.guest-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/vmbox-guest-agent</string>
        <string>-port</string>
        <string>7000</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/vmbox-guest-agent.log</string>
</dict>
</plist>
```

`guest-agent/install/install-macos.sh`:

```bash
#!/bin/bash
# Instala vmbox-guest-agent en macOS como LaunchAgent (sesión del usuario, para el portapapeles).
# Uso: sudo "/Volumes/My Shared Files/GuestTools/install-macos.sh"
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta con sudo"; exit 1; }
USER_NAME="${SUDO_USER:?Ejecuta con sudo desde tu usuario}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchAgents/cl.multiapi.vmbox.guest-agent.plist

mkdir -p /usr/local/bin
install -m 0755 "$HERE/darwin-arm64/vmbox-guest-agent" /usr/local/bin/vmbox-guest-agent
install -m 0644 "$HERE/cl.multiapi.vmbox.guest-agent.plist" "$PLIST"

# run_command con as_root usa «sudo -n»: sudo sin contraseña para este usuario (VM desechable).
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vmbox-guest-agent
chmod 0440 /etc/sudoers.d/vmbox-guest-agent
visudo -cf /etc/sudoers.d/vmbox-guest-agent

USER_ID=$(id -u "$USER_NAME")
launchctl bootout "gui/$USER_ID" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$PLIST"
echo "vmbox-guest-agent instalado y en marcha (vsock:7000)."
```

Run: `scripts/build-guest-agent.sh && ls guest-agent/dist/GuestTools`
Expected: `cl.multiapi.vmbox.guest-agent.plist  darwin-arm64  install-linux.sh  install-macos.sh  linux-arm64  vmbox-guest-agent.service`

- [ ] **Paso 4: humo de vsock en cada invitado (riesgo de la fase)**

Compartir `guest-agent/dist/GuestTools` con cada VM como carpeta de solo lectura (Configuración ▸ Carpetas compartidas, de la Fase 3) e iniciarla.

- Ubuntu: `sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox && /mnt/vmbox/GuestTools/linux-arm64/vmbox-guest-agent -port 7000`
- macOS: `"/Volumes/My Shared Files/GuestTools/darwin-arm64/vmbox-guest-agent" -port 7000`

Expected en ambos: `vmbox-guest-agent 0.1.0 escuchando en vsock:7000` y el proceso sigue vivo (sin `bind vsock:7000: …`). Cortar con Ctrl+C. **Si macOS falla al crear o enlazar el socket AF_VSOCK, detenerse y consultar** (afecta al diseño de la fase para invitados macOS).

- [ ] **Paso 5: commit**

```bash
git add scripts/build-guest-agent.sh scripts/build.sh guest-agent/install
git commit -m "build(guest-agent): compilación cruzada e instaladores para Ubuntu y macOS"
```

---

### Tarea 4.3: Cliente del guest-agent en el host

**Archivos:**
- Modificar: `Packages/VMCore/Sources/ControlProtocol/Messages.swift`
- Crear: `Packages/VMCore/Sources/ControlProtocol/GuestAgentClient.swift`, `Packages/VMCore/Tests/ControlProtocolTests/GuestAgentClientTests.swift`

**Interfaces:**
- Consume: `RPC.exchange`, `RPC.runOnThread`, `LineChannel`, `ControlError`.
- Produce: `ControlErrorCode.guestAgentUnavailable` (`"guest_agent_unavailable"`); `GuestAgent.port: UInt32 = 7000`; `protocol GuestConnecting: Sendable { func connect() async throws -> Int32 }`; `GuestAgentClient(connector:)` con `call(method:params:timeout:) async throws -> JSONValue`.

- [ ] **Paso 1: código de error nuevo**

En `ControlErrorCode` (`Messages.swift`), añade:

```swift
    case guestAgentUnavailable = "guest_agent_unavailable"
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/ControlProtocolTests/GuestAgentClientTests.swift`:

```swift
import Darwin
import XCTest
@testable import ControlProtocol

/// Invitado simulado: un socketpair cuyo otro extremo responde una línea (o se cierra si `respond` devuelve nil).
struct FakeGuest: GuestConnecting {
    let respond: @Sendable (ControlRequest) -> String?

    func connect() async throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let guestFD = fds[1]
        let respond = self.respond
        Thread {
            let channel = LineChannel(fd: guestFD)
            defer { channel.close() }
            guard let line = try? channel.readLine(),
                  let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else { return }
            if let reply = respond(request) { try? channel.writeLine(Data(reply.utf8)) }
        }.start()
        return fds[0]
    }
}

struct RefusingGuest: GuestConnecting {
    func connect() async throws -> Int32 { throw POSIXError(.ECONNREFUSED) }
}

final class GuestAgentClientTests: XCTestCase {
    func testRoundTripWithGoShapedResponse() async throws {
        let guest = FakeGuest { request in
            #"{"jsonrpc":"2.0","id":\#(request.id),"result":{"stdout":"hola\n","exit_code":0}}"#
        }
        let result = try await GuestAgentClient(connector: guest).call(method: "run_command", params: ["command": "echo hola"], timeout: 5)
        XCTAssertEqual(result, ["stdout": "hola\n", "exit_code": 0])
    }

    func testGuestErrorIsPropagated() async {
        let guest = FakeGuest { request in
            #"{"jsonrpc":"2.0","id":\#(request.id),"error":{"code":-32000,"message":"path debe ser absoluta","data":"invalid_argument"}}"#
        }
        do {
            _ = try await GuestAgentClient(connector: guest).call(method: "read_file", params: ["path": "x"], timeout: 5)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error, ControlError(code: .invalidArgument, message: "path debe ser absoluta"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRefusedConnectionIsGuestAgentUnavailable() async {
        do {
            _ = try await GuestAgentClient(connector: RefusingGuest()).call(method: "ping", params: [:], timeout: 1)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .guestAgentUnavailable)
            XCTAssertTrue(error.message.contains("7000"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testClosedWithoutAnswerIsGuestAgentUnavailable() async {
        do {
            _ = try await GuestAgentClient(connector: FakeGuest { _ in nil }).call(method: "ping", params: [:], timeout: 2)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .guestAgentUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSlowGuestTimesOut() async {
        let guest = FakeGuest { request in
            Thread.sleep(forTimeInterval: 2)
            return #"{"jsonrpc":"2.0","id":\#(request.id),"result":{}}"#
        }
        do {
            _ = try await GuestAgentClient(connector: guest).call(method: "run_command", params: [:], timeout: 0.3)
            XCTFail("debió lanzar")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .timeout)
        } catch {
            XCTFail("\(error)")
        }
    }
}
```

- [ ] **Paso 3: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter GuestAgentClientTests`
Expected: FAIL de compilación (`cannot find type 'GuestConnecting' in scope`)

- [ ] **Paso 4: implementación**

`Packages/VMCore/Sources/ControlProtocol/GuestAgentClient.swift`:

```swift
import Foundation

public enum GuestAgent {
    public static let port: UInt32 = 7000
}

/// Abre una conexión nueva con el guest-agent y devuelve su descriptor; `GuestAgentClient` lo cierra.
public protocol GuestConnecting: Sendable {
    func connect() async throws -> Int32
}

/// Cliente del guest-agent: una conexión por llamada, mismo JSON-RPC por líneas que el socket de control.
public struct GuestAgentClient: Sendable {
    let connector: any GuestConnecting

    public init(connector: any GuestConnecting) {
        self.connector = connector
    }

    public func call(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        let fd: Int32
        do {
            fd = try await connector.connect()
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: .guestAgentUnavailable,
                               message: "El guest-agent no responde en vsock:\(GuestAgent.port). Instálalo desde Configuración de la VM ▸ Guest agent. (\(error.localizedDescription))")
        }
        do {
            return try await RPC.runOnThread { try RPC.exchange(fd: fd, method: method, params: params, timeout: timeout) }
        } catch let error as ControlError where error.code == .appUnavailable {
            throw ControlError(code: .guestAgentUnavailable, message: "El guest-agent cerró la conexión sin responder")
        }
    }
}
```

- [ ] **Paso 5: verificar que pasa**

Run: `swift test --package-path Packages/VMCore --filter GuestAgentClientTests`
Expected: PASS (5 tests)

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(control): cliente del guest-agent sobre una conexión por llamada"
```

---

### Tarea 4.4: Herramientas MCP del guest-agent

**Archivos:**
- Modificar: `Packages/VMCore/Sources/AgentControl/VMControlling.swift`, `Packages/VMCore/Sources/AgentControl/ControlService.swift`, `Packages/VMCore/Sources/MCPBridge/ToolCatalog.swift`, `Packages/VMCore/Tests/AgentControlTests/Fakes.swift`, `Packages/VMCore/Tests/MCPBridgeTests/BridgeTests.swift`
- Crear: `Packages/VMCore/Tests/AgentControlTests/GuestToolsTests.swift`

**Interfaces:**
- Consume: `GuestAgentClient` (vía la app), `ControlError.guestAgentUnavailable`.
- Produce: requisito `VMControlling.guestCall(method:params:timeout:) async throws -> JSONValue`; `ControlService` valida y reenvía `run_command`, `read_file`, `write_file`, `clipboard_get`, `clipboard_set` (sin el parámetro `vm`); timeout del guest: `timeout_s + 10` para `run_command`, 30 s para el resto.

- [ ] **Paso 1: ampliar el fake**

En `Packages/VMCore/Tests/AgentControlTests/Fakes.swift`, añade a `FakeVM`:

```swift
    var guestCalls: [(method: String, params: [String: JSONValue], timeout: Double)] = []
    var guestReply: JSONValue = ["ok": true]

    func guestCall(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        guestCalls.append((method, params, timeout))
        return guestReply
    }
```

- [ ] **Paso 2: tests que fallan**

`Packages/VMCore/Tests/AgentControlTests/GuestToolsTests.swift`:

```swift
import AgentControl
import ControlProtocol
import XCTest
import VMCore

@MainActor
final class GuestToolsTests: XCTestCase {
    var vm: FakeVM!
    var service: ControlService!

    override func setUp() async throws {
        vm = FakeVM(name: "Ubuntu")
        service = ControlService(directory: FakeDirectory([vm, FakeVM(name: "Privada", agentControlEnabled: false)]))
    }

    func call(_ method: String, _ params: [String: JSONValue]) async -> ControlResponse {
        await service.handle(ControlRequest(id: 1, method: method, params: params))
    }

    func testRunCommandIsForwardedWithoutVMAndWithTimeout() async throws {
        vm.guestReply = ["stdout": "Linux\n", "exit_code": 0]
        let result = try await call("run_command", ["vm": "Ubuntu", "command": "uname", "timeout_s": 100, "as_root": true]).get()
        XCTAssertEqual(result, ["stdout": "Linux\n", "exit_code": 0])
        XCTAssertEqual(vm.guestCalls.first?.method, "run_command")
        XCTAssertEqual(vm.guestCalls.first?.params, ["command": "uname", "timeout_s": 100, "as_root": true])
        XCTAssertEqual(vm.guestCalls.first?.timeout, 110)
    }

    func testDefaultTimeoutIs60PlusMargin() async throws {
        _ = try await call("run_command", ["vm": "Ubuntu", "command": "true"]).get()
        XCTAssertEqual(vm.guestCalls.first?.timeout, 70)
    }

    func testFileAndClipboardToolsAreForwarded() async throws {
        _ = try await call("read_file", ["vm": "Ubuntu", "path": "/etc/hostname"]).get()
        _ = try await call("write_file", ["vm": "Ubuntu", "path": "/tmp/a", "content": "x"]).get()
        _ = try await call("clipboard_get", ["vm": "Ubuntu"]).get()
        _ = try await call("clipboard_set", ["vm": "Ubuntu", "text": "hola"]).get()
        XCTAssertEqual(vm.guestCalls.map(\.method), ["read_file", "write_file", "clipboard_get", "clipboard_set"])
        XCTAssertEqual(vm.guestCalls.map(\.timeout), [30, 30, 30, 30])
    }

    func testValidationHappensBeforeContactingGuest() async {
        let cases: [(String, [String: JSONValue])] = [
            ("run_command", ["vm": "Ubuntu"]),
            ("run_command", ["vm": "Ubuntu", "command": "  "]),
            ("run_command", ["vm": "Ubuntu", "command": "ls", "timeout_s": 0]),
            ("run_command", ["vm": "Ubuntu", "command": "ls", "timeout_s": 7200]),
            ("read_file", ["vm": "Ubuntu", "path": "relativa"]),
            ("write_file", ["vm": "Ubuntu", "path": "/tmp/a"]),
            ("clipboard_set", ["vm": "Ubuntu"]),
        ]
        for (method, params) in cases {
            let response = await call(method, params)
            XCTAssertEqual(response.error?.data, .invalidArgument, "\(method) \(params)")
        }
        XCTAssertTrue(vm.guestCalls.isEmpty)
    }

    func testPermissionsAndState() async {
        let disabled = await call("run_command", ["vm": "Privada", "command": "ls"])
        XCTAssertEqual(disabled.error?.data, .agentControlDisabled)
        vm.state = .stopped
        let stopped = await call("run_command", ["vm": "Ubuntu", "command": "ls"])
        XCTAssertEqual(stopped.error?.data, .vmNotRunning)
        XCTAssertTrue(vm.guestCalls.isEmpty)
    }
}
```

- [ ] **Paso 3: verificar que falla**

Run: `swift test --package-path Packages/VMCore --filter GuestToolsTests`
Expected: FAIL — `run_command` y compañía responden `invalid_argument: Método desconocido`.

- [ ] **Paso 4: implementación**

En `VMControlling.swift`, dentro del protocolo:

```swift
    /// Llama al guest-agent de la VM (la VM debe estar en ejecución).
    func guestCall(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue
```

y añade `import ControlProtocol` al principio del archivo.

En `ControlService.swift`:

1. Amplía `vmMethods` con los métodos del invitado:

```swift
    static let guestMethods: Set<String> = ["run_command", "read_file", "write_file", "clipboard_get", "clipboard_set"]
    static let vmMethods: Set<String> = Set(["start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                                             "snapshot_create", "snapshot_list", "snapshot_restore"]).union(guestMethods)
```

2. Añade los structs de validación:

```swift
    struct CommandParams: Decodable {
        var command: String; var timeoutS: Double?; var asRoot: Bool?
        enum CodingKeys: String, CodingKey { case command, timeoutS = "timeout_s", asRoot = "as_root" }
    }
    struct PathParams: Decodable { var path: String }
    struct WriteParams: Decodable { var path: String; var content: String }
    struct ClipboardParams: Decodable { var text: String }
```

3. Añade este caso al `switch` de `dispatch`, antes de `default:`:

```swift
        case let method where Self.guestMethods.contains(method):
            try requireRunning(vm)
            var timeout = 30.0
            switch method {
            case "run_command":
                let p = try params.decode(as: CommandParams.self)
                guard !p.command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ControlError(code: .invalidArgument, message: "Falta el parámetro «command»")
                }
                let seconds = p.timeoutS ?? 60
                guard seconds > 0, seconds <= 3600 else {
                    throw ControlError(code: .invalidArgument, message: "timeout_s debe estar entre 1 y 3600")
                }
                timeout = seconds + 10
            case "read_file":
                try Self.requireAbsolute(try params.decode(as: PathParams.self).path)
            case "write_file":
                try Self.requireAbsolute(try params.decode(as: WriteParams.self).path)
            case "clipboard_set":
                _ = try params.decode(as: ClipboardParams.self)
            default:
                break
            }
            var forwarded = request.params
            forwarded.removeValue(forKey: "vm")
            let result = try await vm.guestCall(method: method, params: forwarded, timeout: timeout)
            onAgentActivity(vm.id)
            return result
```

4. Añade el ayudante:

```swift
    static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw ControlError(code: .invalidArgument, message: "path debe ser absoluta: \(path)")
        }
    }
```

En `ToolCatalog.swift`, añade al final de `specs`:

```swift
        ToolSpec(name: "run_command",
                 description: "Run a shell command inside the VM via the guest agent. Returns stdout, stderr, exit_code, timed_out, truncated (outputs capped at 1 MB).",
                 properties: ["vm": vm, "command": string("Shell command (/bin/sh -c)"),
                              "timeout_s": number("Seconds before the command is killed (default 60, max 3600)"),
                              "as_root": boolean("Run with sudo")],
                 required: ["vm", "command"],
                 timeout: { args in (args["timeout_s"]?.doubleValue ?? 60) + 15 }),
        ToolSpec(name: "read_file", description: "Read a file inside the VM (absolute path, max 10 MB). Binary files come back base64 encoded.",
                 properties: ["vm": vm, "path": string("Absolute path in the guest")], required: ["vm", "path"], timeout: fixed(40)),
        ToolSpec(name: "write_file", description: "Write a file inside the VM (absolute path; the parent directory must exist).",
                 properties: ["vm": vm, "path": string("Absolute path in the guest"), "content": string("File content"),
                              "encoding": oneOf(["utf8", "base64"], "Content encoding (default utf8)")],
                 required: ["vm", "path", "content"], timeout: fixed(40)),
        ToolSpec(name: "clipboard_get", description: "Read the guest clipboard as text.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(40)),
        ToolSpec(name: "clipboard_set", description: "Set the guest clipboard text (useful for non-ASCII text: then paste with key).",
                 properties: ["vm": vm, "text": string("Text to copy")], required: ["vm", "text"], timeout: fixed(40)),
```

En `BridgeTests.testCatalogMatchesSpec`, reemplaza la lista esperada por:

```swift
                       ["list_vms", "start_vm", "stop_vm", "screenshot", "click", "drag", "scroll", "type_text", "key",
                        "snapshot_create", "snapshot_list", "snapshot_restore",
                        "run_command", "read_file", "write_file", "clipboard_get", "clipboard_set"])
```

- [ ] **Paso 5: verificar que pasa**

Run: `swift test --package-path Packages/VMCore`
Expected: PASS (todos)

- [ ] **Paso 6: commit**

```bash
git add Packages/VMCore
git commit -m "feat(agent): herramientas MCP del guest-agent con validación previa"
```

---

### Tarea 4.5: App — conector vsock, empaquetado de GuestTools e instalación desde la UI

**Archivos:**
- Crear: `VMBox/Control/VsockGuestConnector.swift`
- Modificar: `VMBox/Model/AgentVMAdapter.swift`, `VMBox/Views/VMSettingsSheet.swift`, `project.yml`

**Interfaces:**
- Consume: `GuestConnecting`, `GuestAgentClient`, `GuestAgent.port`, `VMInstance.machine`, `SharedFolder`.
- Produce: `VsockGuestConnector(instance:)`; `AgentVMAdapter.guestCall`; `VMBox.app/Contents/Resources/GuestTools`; sección "Guest agent" en la configuración de la VM.

- [ ] **Paso 1: conector vsock**

`VMBox/Control/VsockGuestConnector.swift`:

```swift
import ControlProtocol
import Darwin
import Virtualization
import VMCore

/// Conecta con el guest-agent por el VZVirtioSocketDevice de la VM.
@MainActor
final class VsockGuestConnector: GuestConnecting {
    private weak var instance: VMInstance?

    init(instance: VMInstance) {
        self.instance = instance
    }

    func connect() async throws -> Int32 {
        guard let device = instance?.machine?.socketDevices.first as? VZVirtioSocketDevice else {
            throw ControlError(code: .vmNotRunning, message: "La VM no está en ejecución")
        }
        let connection = try await device.connect(toPort: GuestAgent.port)
        // La conexión cierra su descriptor al liberarse: duplicarlo para que lo gestione LineChannel.
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { throw ControlError(code: .internalError, message: "dup falló: \(errno)") }
        return fd
    }
}
```

- [ ] **Paso 2: `guestCall` en el adaptador**

En `VMBox/Model/AgentVMAdapter.swift`, añade:

```swift
    func guestCall(method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        try await GuestAgentClient(connector: VsockGuestConnector(instance: instance))
            .call(method: method, params: params, timeout: timeout)
    }
```

- [ ] **Paso 3: empaquetar GuestTools en el bundle**

En `project.yml`, reemplaza `sources: [VMBox]` del target `VMBox` por:

```yaml
    sources:
      - path: VMBox
      - path: guest-agent/dist/GuestTools
        type: folder
        buildPhase: resources
```

Run: `scripts/build.sh && ls build/Build/Products/Debug/VMBox.app/Contents/Resources/GuestTools`
Expected: `BUILD SUCCEEDED` y el listado de GuestTools (binarios y scripts). (`scripts/build.sh` ya corre `build-guest-agent.sh` antes de `xcodegen`, porque la carpeta debe existir al generar el proyecto.)

- [ ] **Paso 4: sección "Guest agent" en la configuración de la VM**

En `VMBox/Views/VMSettingsSheet.swift`:

1. Añade estas propiedades calculadas a `VMSettingsSheet`:

```swift
    private var guestToolsPath: String? {
        Bundle.main.url(forResource: "GuestTools", withExtension: nil)?.path
    }

    private func installCommand(for os: GuestOS) -> String {
        switch os {
        case .linux:
            "sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox && sudo /mnt/vmbox/GuestTools/install-linux.sh"
        case .macOS:
            "sudo \"/Volumes/My Shared Files/GuestTools/install-macos.sh\""
        }
    }
```

2. Después de la `Section("Carpetas compartidas")` (y antes del texto "Detén la VM…"), añade:

```swift
                if let toolsPath = guestToolsPath {
                    Section("Guest agent (comandos, archivos, portapapeles)") {
                        Toggle("Compartir el instalador con la VM", isOn: Binding(
                            get: { folders.contains { $0.path == toolsPath } },
                            set: { share in
                                folders.removeAll { $0.path == toolsPath }
                                if share { folders.append(SharedFolder(path: toolsPath, readOnly: true)) }
                            }
                        ))
                        Text("Guarda, inicia la VM y ejecuta en su terminal:").font(.caption)
                        Text(installCommand(for: vm.config.os))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .disabled(!editable)
                }
```

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`

- [ ] **Paso 5: instalar y probar en Ubuntu**

Expected:
1. Ubuntu detenida → Configuración → "Compartir el instalador con la VM" → Guardar → Iniciar (sesión iniciada).
2. En la terminal de la VM, el comando mostrado termina con `vmbox-guest-agent instalado y en marcha (vsock:7000).`
3. Run:

```bash
scripts/mcp_smoke.py build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu "run:uname -a"
```

Expected: `run_command … isError=False` con `"stdout" : "Linux … aarch64 …"` y `"exit_code" : 0`.
4. Reiniciar la VM y repetir el paso 3: el agente arranca solo al iniciar sesión.
5. Detener el servicio (`systemctl --user stop vmbox-guest-agent`) y repetir: `isError=True` con `guest_agent_unavailable: El guest-agent no responde en vsock:7000…`.

- [ ] **Paso 6: instalar y probar en macOS**

Expected: igual que en Ubuntu con el comando de macOS; `scripts/mcp_smoke.py … macOS "run:sw_vers"` devuelve `ProductName: macOS`.

- [ ] **Paso 7: commit**

```bash
git add VMBox project.yml
git commit -m "feat(app): conector vsock al guest-agent e instalación desde la configuración de la VM"
```

---

### Tarea 4.6: Aceptación final del MVP

**Archivos:**
- Modificar: `README.md`

**Interfaces:** ninguna nueva.

- [ ] **Paso 1: herramientas del invitado desde Claude Code**

Expected, pidiendo a Claude Code en lenguaje natural:
1. «Instala htop en la VM de Ubuntu» → usa `run_command` con `as_root: true` (`apt-get install -y htop`) y lo verifica con `htop --version`.
2. «Escribe "hola ñandú" en un archivo /tmp/nota.txt de la VM Ubuntu y léelo» → `write_file` + `read_file` devuelven el texto con tildes intacto.
3. «Pon "configuración" en el portapapeles de la VM macOS y pégalo en TextEdit» → `clipboard_set` + `key cmd+v`.

- [ ] **Paso 2: criterio de éxito de la spec (§1)**

Expected:
1. «Abre Safari en la VM de macOS y busca Virtualization framework» → el agente lo logra solo con `screenshot`/`click`/`key`/`type_text`.
2. «Crea un snapshot "antes" de la VM Ubuntu, borra ~/Documents con un comando y luego vuelve al snapshot» → tras `snapshot_restore` (con `confirm: true`) y `start_vm`, `~/Documents` existe de nuevo.
3. Durante todo, el cursor y el teclado de la Mac anfitriona no se mueven, y Ajustes ▸ Log del MCP registra cada llamada.

- [ ] **Paso 3: README**

Añade a `README.md`:

````markdown
## Guest agent (comandos, archivos, portapapeles)
1. Configuración de la VM ▸ **Compartir el instalador con la VM** ▸ Guardar e iniciar la VM.
2. En la terminal del invitado, ejecuta el comando que muestra la configuración (Ubuntu o macOS).
   El instalador configura `sudo` sin contraseña para tu usuario (necesario para `as_root`): úsalo solo en VMs desechables.
3. Herramientas MCP: `run_command`, `read_file`, `write_file`, `clipboard_get`, `clipboard_set`.
   Si el agente no está instalado o no corre, devuelven `guest_agent_unavailable`.

Compilar solo el guest-agent:
```bash
scripts/build-guest-agent.sh
```
````

- [ ] **Paso 4: commit**

```bash
git add README.md
git commit -m "docs: guest agent y aceptación del MVP"
```
