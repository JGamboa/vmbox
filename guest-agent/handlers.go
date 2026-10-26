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
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	version        = "0.2.0"
	maxOutputBytes = 1 << 20
	maxFileBytes   = 10 << 20
	maxTimeout     = time.Hour
)

type Handler struct {
	Shell      []string // p. ej. ["/bin/sh", "-c"]
	RootPrefix []string // p. ej. ["sudo", "-n"]
	Clipboard  Clipboard
	// CgroupDir: cgroup v2 del servicio; si no está vacío, cancel_all mata también todo lo que contenga.
	CgroupDir string

	mu     sync.Mutex
	groups map[int]struct{} // grupos de procesos de los comandos lanzados
}

func NewHandler() *Handler {
	return &Handler{Shell: []string{"/bin/sh", "-c"}, RootPrefix: []string{"sudo", "-n"}, Clipboard: SystemClipboard()}
}

func (h *Handler) Dispatch(method string, params json.RawMessage) (any, *RPCError) {
	return h.DispatchContext(context.Background(), method, params)
}

// DispatchContext atiende una petición; cancelar ctx (p. ej. el anfitrión cerró la conexión) mata el comando en curso.
func (h *Handler) DispatchContext(ctx context.Context, method string, params json.RawMessage) (any, *RPCError) {
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
		return h.runCommand(ctx, p.Command, timeout, p.AsRoot)
	case "cancel_all":
		return h.cancelAll()
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

func (h *Handler) runCommand(parent context.Context, command string, timeout time.Duration, asRoot bool) (any, *RPCError) {
	if strings.TrimSpace(command) == "" {
		return nil, invalidArgument("falta el parámetro «command»")
	}
	args := append(append([]string{}, h.Shell...), command)
	if asRoot {
		args = append(append([]string{}, h.RootPrefix...), args...)
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	// Grupo de procesos propio para matar también a los hijos del shell al vencer el timeout.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	var stdout, stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	if err := cmd.Start(); err != nil {
		if parent.Err() != nil {
			return nil, internalError("petición cancelada")
		}
		return nil, internalError("no se pudo ejecutar el comando: " + err.Error())
	}
	pgid := cmd.Process.Pid
	h.trackGroup(pgid)
	err := cmd.Wait()
	h.releaseGroup(pgid)
	if parent.Err() != nil {
		return nil, internalError("petición cancelada")
	}
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	exitCode := 0
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		exitCode = exitErr.ExitCode()
	case timedOut:
	case errors.Is(err, exec.ErrWaitDelay):
		// Un hijo en segundo plano retiene stdout/stderr: el comando terminó, la salida capturada es válida.
		if cmd.ProcessState != nil {
			exitCode = cmd.ProcessState.ExitCode()
		}
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
