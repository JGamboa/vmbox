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
