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
