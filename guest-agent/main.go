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
		if err := Serve(stdio{}, h, false); err != nil {
			log.Fatal(err)
		}
		return
	}
	if data, err := os.ReadFile("/proc/self/cgroup"); err == nil {
		if dir, ok := serviceCgroupDir(string(data)); ok {
			h.CgroupDir = dir
		}
	}
	log.Printf("vmbox-guest-agent %s escuchando en vsock:%d", version, *port)
	log.Fatal(ListenVsock(uint32(*port), func(conn *os.File) {
		defer conn.Close()
		if err := Serve(conn, h, true); err != nil {
			log.Printf("conexión: %v", err)
		}
	}))
}
