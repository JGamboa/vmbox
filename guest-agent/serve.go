package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
)

// Serve atiende peticiones JSON-RPC, una por línea, hasta EOF.
// Con cancelOnClose, si el otro extremo cierra la conexión se cancela la petición en curso
// (y se mata su comando): el anfitrión cierra las conexiones al retirar el control de agente.
func Serve(rw io.ReadWriter, h *Handler, cancelOnClose bool) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lines := make(chan []byte)
	var readErr error
	go func() {
		defer close(lines)
		reader := bufio.NewReaderSize(rw, 64*1024)
		for {
			line, err := reader.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				select {
				case lines <- line:
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				if err != io.EOF {
					readErr = err
				}
				if cancelOnClose {
					cancel()
				}
				return
			}
		}
	}()
	encoder := json.NewEncoder(rw)
	encoder.SetEscapeHTML(false)
	for line := range lines {
		response := Response{JSONRPC: "2.0"}
		var request Request
		if err := json.Unmarshal(line, &request); err != nil {
			response.Error = invalidArgument("mensaje JSON-RPC inválido")
		} else {
			response.ID = request.ID
			response.Result, response.Error = h.DispatchContext(ctx, request.Method, request.Params)
		}
		if ctx.Err() != nil {
			return nil // nadie espera ya la respuesta
		}
		if err := encoder.Encode(response); err != nil {
			return err
		}
	}
	return readErr
}
