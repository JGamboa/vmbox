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

## Control por agentes (MCP)
1. En la ventana de la VM, activa **Permitir control de agente**.
2. VMBox ▸ Ajustes ▸ **Copiar comando para Claude Code** y ejecútalo, o:
   ```bash
   claude mcp add vmbox -- "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"
   ```
3. Herramientas: `list_vms`, `start_vm`, `stop_vm`, `screenshot`, `click`, `drag`, `scroll`, `type_text`, `key`.
   `type_text` usa distribución de teclado US: configura el invitado con teclado US.
4. Prueba rápida sin Claude: `scripts/mcp_smoke.py <ruta a vmbox-mcp> <vm> list start screenshot:/tmp/a.png`.

## Snapshots y carpetas compartidas
- 📸 en la ventana de la VM (o «Snapshots» en la biblioteca). Con la VM encendida se guarda también la memoria;
  al restaurar, la VM queda detenida y el siguiente inicio continúa desde el snapshot.
- MCP: `snapshot_create`, `snapshot_list`, `snapshot_restore` (exige `confirm: true`).
- Carpetas compartidas: Configuración de la VM ▸ Carpetas compartidas. En macOS aparecen en
  `/Volumes/My Shared Files`; en Ubuntu: `sudo mount -t virtiofs vmbox /mnt/vmbox`.
