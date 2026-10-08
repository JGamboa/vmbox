#!/usr/bin/env python3
"""Prueba de humo: habla MCP por stdio con vmbox-mcp y ejecuta una secuencia de herramientas.

Uso: scripts/mcp_smoke.py <ruta a vmbox-mcp> <vm> paso [paso...]
Pasos: list | start | stop | screenshot:<archivo.png> | key:<combo> | type:<texto, \\n = Enter>
       | click:<x>,<y> | sleep:<segundos> | snapshot:<nombre> | restore:<nombre> | run:<comando>
       | expect-error:<código> (el siguiente paso debe fallar con ese código)
"""
import base64
import json
import subprocess
import sys
import time


def main() -> None:
    exe, vm, steps = sys.argv[1], sys.argv[2], sys.argv[3:]
    proc = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    counter = [0]

    def rpc(method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            counter[0] += 1
            message["id"] = counter[0]
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()
        if notify:
            return None
        while True:
            line = proc.stdout.readline()
            if not line:
                raise SystemExit("vmbox-mcp terminó inesperadamente")
            response = json.loads(line)
            if response.get("id") == message["id"]:
                return response

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "smoke", "version": "0"}})
    rpc("notifications/initialized", notify=True)

    expected_error = [None]

    def tool(name, args):
        result = rpc("tools/call", {"name": name, "arguments": args})["result"]
        texts = " ".join(c["text"] for c in result["content"] if c["type"] == "text")
        images = [c["data"] for c in result["content"] if c["type"] == "image"]
        print(f"{name} {json.dumps(args)[:120]} -> isError={result.get('isError')} {texts[:300]}")
        if expected_error[0]:
            code, expected_error[0] = expected_error[0], None
            if not (result.get("isError") and texts.startswith(code)):
                raise SystemExit(f"se esperaba el error {code}")
            return []
        if result.get("isError"):
            raise SystemExit(1)
        return images

    for step in steps:
        kind, _, arg = step.partition(":")
        if kind == "list":
            tool("list_vms", {})
        elif kind == "start":
            tool("start_vm", {"vm": vm})
        elif kind == "stop":
            tool("stop_vm", {"vm": vm, "force": True})
        elif kind == "screenshot":
            image = tool("screenshot", {"vm": vm})
            if image:
                with open(arg, "wb") as f:
                    f.write(base64.b64decode(image[0]))
                print(f"  guardada {arg}")
        elif kind == "key":
            tool("key", {"vm": vm, "combo": arg})
        elif kind == "type":
            tool("type_text", {"vm": vm, "text": arg.replace("\\n", "\n")})
        elif kind == "click":
            x, y = arg.split(",")
            tool("click", {"vm": vm, "x": float(x), "y": float(y)})
        elif kind == "sleep":
            time.sleep(float(arg))
        elif kind == "snapshot":
            tool("snapshot_create", {"vm": vm, "name": arg})
        elif kind == "restore":
            tool("snapshot_restore", {"vm": vm, "name": arg, "confirm": True})
        elif kind == "run":
            tool("run_command", {"vm": vm, "command": arg})
        elif kind == "expect-error":
            expected_error[0] = arg
        else:
            raise SystemExit(f"paso desconocido: {step}")

    proc.stdin.close()
    proc.wait(timeout=10)


if __name__ == "__main__":
    main()
