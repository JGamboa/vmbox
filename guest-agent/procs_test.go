package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func alive(pid int) bool { return !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) }

// waitDead espera a que el proceso desaparezca (huérfano recogido por init/launchd).
func waitDead(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for alive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("el proceso %d sigue vivo", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func readPID(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		data, _ := os.ReadFile(path)
		if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			return pid
		}
		if time.Now().After(deadline) {
			t.Fatalf("el comando no escribió su pid en %s", path)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestCancelAllKillsInFlightCommand(t *testing.T) {
	h := testHandler()
	pidFile := filepath.Join(t.TempDir(), "pid")
	done := make(chan map[string]any, 1)
	start := time.Now()
	go func() {
		r, _ := call(t, h, "run_command", map[string]any{"command": "echo $$ > " + pidFile + "; sleep 30", "timeout_s": 60})
		done <- r
	}()
	pid := readPID(t, pidFile)

	r, err := call(t, h, "cancel_all", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if r["killed"].(int) < 1 {
		t.Fatalf("cancel_all no mató nada: %#v", r)
	}
	select {
	case result := <-done:
		if result["exit_code"] == 0 {
			t.Fatalf("el comando no debió terminar bien: %#v", result)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run_command siguió en curso tras cancel_all")
	}
	if time.Since(start) > 10*time.Second {
		t.Fatalf("tardó demasiado: %v", time.Since(start))
	}
	waitDead(t, pid)
}

func TestCancelAllKillsBackgroundProcessesThatOutliveTheCommand(t *testing.T) {
	h := testHandler()
	r, err := call(t, h, "run_command", map[string]any{"command": "sleep 60 >/dev/null 2>&1 & echo $!"})
	if err != nil {
		t.Fatal(err)
	}
	pid, convErr := strconv.Atoi(strings.TrimSpace(r["stdout"].(string)))
	if convErr != nil || !alive(pid) {
		t.Fatalf("no quedó un proceso en segundo plano: %#v", r)
	}
	if len(h.trackedGroups()) != 1 {
		t.Fatalf("el grupo con un hijo vivo debe seguir registrado: %v", h.trackedGroups())
	}

	if _, err := call(t, h, "cancel_all", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	waitDead(t, pid)
	if len(h.trackedGroups()) != 0 {
		t.Fatalf("los grupos vacíos deben olvidarse: %v", h.trackedGroups())
	}
}

func TestFinishedCommandGroupIsForgotten(t *testing.T) {
	h := testHandler()
	if _, err := call(t, h, "run_command", map[string]any{"command": "true"}); err != nil {
		t.Fatal(err)
	}
	if len(h.trackedGroups()) != 0 {
		t.Fatalf("un grupo sin procesos no debe quedar registrado: %v", h.trackedGroups())
	}
}

func TestCancelAllWithNothingRunningReportsNoSurvivors(t *testing.T) {
	r, err := call(t, testHandler(), "cancel_all", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if survivors, ok := r["survivors"].([]int); !ok || len(survivors) != 0 {
		t.Fatalf("resultado inesperado: %#v", r)
	}
}

func TestClosingTheConnectionKillsTheInFlightCommand(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "pid")
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	go func() { _, _ = io.Copy(io.Discard, bufio.NewReader(outR)) }()
	served := make(chan error, 1)
	go func() { served <- Serve(pipeRW{inR, outW}, testHandler(), true) }()

	request := `{"jsonrpc":"2.0","id":1,"method":"run_command","params":{"command":"echo $$ > ` + pidFile + `; sleep 30","timeout_s":60}}` + "\n"
	if _, err := inW.Write([]byte(request)); err != nil {
		t.Fatal(err)
	}
	pid := readPID(t, pidFile)
	inW.Close() // el anfitrión cierra la conexión

	select {
	case <-served:
	case <-time.After(5 * time.Second):
		t.Fatal("Serve no terminó al cerrarse la conexión")
	}
	waitDead(t, pid)
}

func TestKillTargetsIncludesDescendantsAndTrackedGroupsButNotSelfOrZombies(t *testing.T) {
	procs := []procInfo{
		{pid: 1, ppid: 0, pgid: 1},
		{pid: 100, ppid: 1, pgid: 100},   // el agente
		{pid: 200, ppid: 100, pgid: 200}, // comando
		{pid: 201, ppid: 200, pgid: 200}, // nieto
		{pid: 300, ppid: 201, pgid: 300}, // bisnieto con grupo propio
		{pid: 400, ppid: 1, pgid: 200},   // huérfano del grupo registrado
		{pid: 500, ppid: 1, pgid: 500},   // ajeno
		{pid: 202, ppid: 100, pgid: 202, zombie: true},
	}
	got := killTargets(procs, 100, map[int]struct{}{200: {}})
	if want := []int{200, 201, 300, 400}; !reflect.DeepEqual(got, want) {
		t.Fatalf("objetivos %v, se esperaba %v", got, want)
	}
}

func TestParseProcStat(t *testing.T) {
	p, ok := parseProcStat(42, "42 (mi (raro) proceso) S 7 42 42 0 -1")
	if !ok || p != (procInfo{pid: 42, ppid: 7, pgid: 42}) {
		t.Fatalf("parse: %#v %v", p, ok)
	}
	z, ok := parseProcStat(43, "43 (sleep) Z 7 42 42 0 -1")
	if !ok || !z.zombie {
		t.Fatalf("zombi no detectado: %#v", z)
	}
	if _, ok := parseProcStat(1, "basura"); ok {
		t.Fatal("debió rechazar una línea inválida")
	}
}

func TestParsePS(t *testing.T) {
	got := parsePS([]byte("    1     0     1 Ss\n  512     1   512 S+\n  513   512   512 Z\ncabecera rara\n"))
	want := []procInfo{{1, 0, 1, false}, {512, 1, 512, false}, {513, 512, 512, true}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parsePS: %#v", got)
	}
}

func TestServiceCgroupDirOnlyForTheAgentService(t *testing.T) {
	dir, ok := serviceCgroupDir("0::/user.slice/user-1000.slice/user@1000.service/app.slice/vmbox-guest-agent.service\n")
	if !ok || dir != "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/vmbox-guest-agent.service" {
		t.Fatalf("cgroup del servicio: %q %v", dir, ok)
	}
	for _, other := range []string{
		"0::/user.slice/user-1000.slice/session-2.scope\n",
		"12:pids:/vmbox-guest-agent.service\n",
		"",
	} {
		if _, ok := serviceCgroupDir(other); ok {
			t.Fatalf("no debió aceptar %q", other)
		}
	}
}
