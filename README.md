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

## Uso básico
- **Nueva VM**: Ubuntu (última LTS o ISO propio) o macOS (último IPSW compatible o IPSW propio).
- Ubuntu: completa el instalador en la ventana de la VM; después, en Configuración, marca «Expulsar» el ISO.
- macOS: completa el Asistente de configuración la primera vez.
- Las VMs viven en `~/Library/Application Support/VMBox/VMs/<nombre>.vmbox/`; las descargas, en `…/VMBox/Cache/`.
