# VMBox

App de macOS para correr VMs de macOS y Ubuntu (Virtualization.framework) controlables por agentes vía MCP.
Diseño: `docs/specs/2026-10-08-vmbox-design.md`. Plan: `docs/plans/`.

## Requisitos
Apple silicon, macOS 26, Xcode 26, `brew install xcodegen`.

## Compilar y probar
```bash
scripts/test.sh
scripts/build.sh
open build/Build/Products/Debug/VMBox.app
```
