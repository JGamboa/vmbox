package main

import (
	"bufio"
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// procInfo es una fila de la tabla de procesos del invitado.
type procInfo struct {
	pid, ppid, pgid int
	zombie          bool
}

// trackGroup registra el grupo de procesos de un comando lanzado por el agente.
func (h *Handler) trackGroup(pgid int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.groups == nil {
		h.groups = map[int]struct{}{}
	}
	h.groups[pgid] = struct{}{}
}

// releaseGroup olvida el grupo solo si ya no le queda ningún proceso (un hijo en segundo plano lo mantiene vivo).
// Un PGID no se reutiliza mientras el grupo exista, así que conservarlo no arriesga matar procesos ajenos.
func (h *Handler) releaseGroup(pgid int) {
	if err := syscall.Kill(-pgid, 0); !errors.Is(err, syscall.ESRCH) {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.groups, pgid)
}

func (h *Handler) trackedGroups() map[int]struct{} {
	h.mu.Lock()
	defer h.mu.Unlock()
	groups := make(map[int]struct{}, len(h.groups))
	for pgid := range h.groups {
		groups[pgid] = struct{}{}
	}
	return groups
}

// cancelAll mata con SIGKILL todo lo que el agente haya lanzado: los grupos de procesos de cada comando,
// los descendientes vivos del agente y, como servicio Linux, todo el cgroup del servicio (que también
// contiene a los que hicieron setsid o doble fork). Repite hasta que no quede ninguno o se agoten las rondas.
func (h *Handler) cancelAll() (any, *RPCError) {
	self := os.Getpid()
	killed := map[int]struct{}{}
	var survivors []int
	for round := 0; ; round++ {
		groups := h.trackedGroups()
		procs, err := listProcesses()
		if err != nil {
			return nil, internalError("no se pudo leer la tabla de procesos: " + err.Error())
		}
		targets := killTargets(procs, self, groups)
		if h.CgroupDir != "" {
			targets = mergePIDs(targets, cgroupPIDs(h.CgroupDir, self, procs))
		}
		if len(targets) == 0 || round == 5 {
			survivors = targets
			break
		}
		for pgid := range groups {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
		var denied []int
		for _, pid := range targets {
			switch err := syscall.Kill(pid, syscall.SIGKILL); {
			case err == nil:
				killed[pid] = struct{}{}
			case errors.Is(err, syscall.EPERM):
				denied = append(denied, pid)
			}
		}
		// Los procesos de as_root pertenecen a root: se matan con el mismo prefijo (sudo -n).
		if len(denied) > 0 && len(h.RootPrefix) > 0 {
			args := append(append([]string{}, h.RootPrefix...), "kill", "-KILL")
			for _, pid := range denied {
				args = append(args, strconv.Itoa(pid))
			}
			if exec.Command(args[0], args[1:]...).Run() == nil {
				for _, pid := range denied {
					killed[pid] = struct{}{}
				}
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	for pgid := range h.trackedGroups() {
		h.releaseGroup(pgid)
	}
	if survivors == nil {
		survivors = []int{}
	}
	return map[string]any{"killed": len(killed), "survivors": survivors}, nil
}

// killTargets devuelve los procesos a matar: descendientes de `self` y miembros de los grupos registrados.
func killTargets(procs []procInfo, self int, groups map[int]struct{}) []int {
	children := map[int][]int{}
	zombies := map[int]struct{}{}
	for _, p := range procs {
		children[p.ppid] = append(children[p.ppid], p.pid)
		if p.zombie {
			zombies[p.pid] = struct{}{}
		}
	}
	set := map[int]struct{}{}
	queue := []int{self}
	for len(queue) > 0 {
		parent := queue[0]
		queue = queue[1:]
		for _, child := range children[parent] {
			if _, seen := set[child]; !seen {
				set[child] = struct{}{}
				queue = append(queue, child)
			}
		}
	}
	for _, p := range procs {
		if _, ok := groups[p.pgid]; ok {
			set[p.pid] = struct{}{}
		}
	}
	delete(set, self)
	// Un zombi ya está muerto: solo espera a que su padre lo recoja.
	for pid := range zombies {
		delete(set, pid)
	}
	return sortedPIDs(set)
}

func mergePIDs(a, b []int) []int {
	set := map[int]struct{}{}
	for _, pid := range append(append([]int{}, a...), b...) {
		set[pid] = struct{}{}
	}
	return sortedPIDs(set)
}

func sortedPIDs(set map[int]struct{}) []int {
	pids := make([]int, 0, len(set))
	for pid := range set {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	return pids
}

// listProcesses lee /proc en Linux y usa ps en macOS.
func listProcesses() ([]procInfo, error) {
	if entries, err := os.ReadDir("/proc"); err == nil {
		var procs []procInfo
		for _, entry := range entries {
			pid, err := strconv.Atoi(entry.Name())
			if err != nil {
				continue
			}
			stat, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "stat"))
			if err != nil {
				continue // terminó mientras se recorría
			}
			if p, ok := parseProcStat(pid, string(stat)); ok {
				procs = append(procs, p)
			}
		}
		return procs, nil
	}
	ps := exec.Command("ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "stat=")
	out, err := ps.Output()
	if err != nil {
		return nil, err
	}
	// ps se lista a sí mismo como hijo del agente, pero ya terminó.
	procs := parsePS(out)
	for i, p := range procs {
		if p.pid == ps.Process.Pid {
			procs = append(procs[:i], procs[i+1:]...)
			break
		}
	}
	return procs, nil
}

// parseProcStat extrae ppid y pgid de /proc/<pid>/stat; el nombre va entre paréntesis y puede tener espacios.
func parseProcStat(pid int, stat string) (procInfo, bool) {
	end := strings.LastIndexByte(stat, ')')
	if end < 0 {
		return procInfo{}, false
	}
	fields := strings.Fields(stat[end+1:])
	if len(fields) < 3 {
		return procInfo{}, false
	}
	zombie := fields[0] == "Z"
	ppid, err1 := strconv.Atoi(fields[1])
	pgid, err2 := strconv.Atoi(fields[2])
	if err1 != nil || err2 != nil {
		return procInfo{}, false
	}
	return procInfo{pid: pid, ppid: ppid, pgid: pgid, zombie: zombie}, true
}

func parsePS(out []byte) []procInfo {
	var procs []procInfo
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 4 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		pgid, err3 := strconv.Atoi(fields[2])
		if err1 != nil || err2 != nil || err3 != nil {
			continue
		}
		procs = append(procs, procInfo{pid: pid, ppid: ppid, pgid: pgid, zombie: strings.HasPrefix(fields[3], "Z")})
	}
	return procs
}

// serviceCgroupDir devuelve el directorio cgroup v2 del agente solo si es su propio servicio de systemd:
// matar el cgroup de una terminal o de un test arrastraría procesos que no son del agente.
func serviceCgroupDir(procSelfCgroup string) (string, bool) {
	for _, line := range strings.Split(strings.TrimSpace(procSelfCgroup), "\n") {
		path, found := strings.CutPrefix(line, "0::")
		if !found {
			continue
		}
		if strings.HasSuffix(path, "/vmbox-guest-agent.service") {
			return filepath.Join("/sys/fs/cgroup", path), true
		}
	}
	return "", false
}

func cgroupPIDs(dir string, self int, procs []procInfo) []int {
	data, err := os.ReadFile(filepath.Join(dir, "cgroup.procs"))
	if err != nil {
		return nil
	}
	zombies := map[int]struct{}{}
	for _, p := range procs {
		if p.zombie {
			zombies[p.pid] = struct{}{}
		}
	}
	set := map[int]struct{}{}
	for _, field := range strings.Fields(string(data)) {
		pid, err := strconv.Atoi(field)
		if _, zombie := zombies[pid]; err == nil && pid != self && !zombie {
			set[pid] = struct{}{}
		}
	}
	return sortedPIDs(set)
}
