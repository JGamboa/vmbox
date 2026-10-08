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
