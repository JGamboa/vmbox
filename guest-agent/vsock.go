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
	unix.CloseOnExec(fd)
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
		unix.CloseOnExec(conn)
		go handle(os.NewFile(uintptr(conn), "vsock"))
	}
}
