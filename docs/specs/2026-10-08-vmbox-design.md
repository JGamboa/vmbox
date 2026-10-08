# VMBox — Diseño (MVP)

Fecha: 2026-10-08 · Autor: Joaquín Gamboa · Estado: aprobado

## 1. Objetivo

App nativa de macOS para crear y correr máquinas virtuales de **macOS** y **Ubuntu** en Apple silicon, pensada para **darle a agentes de IA (Claude Code y otros) su propia máquina** donde instalar, hacer clic y romper cosas sin tocar la Mac anfitriona. Inspirada en [VMPal](https://vmpal.com/).

**Para quién:** uso propio / equipo, y como proyecto de aprendizaje de `Virtualization.framework` y MCP. UI funcional, sin pulido de producto. Se valora código claro por sobre acabado.

**Éxito del MVP:** desde Claude Code, con el MCP de VMBox registrado, pedir *"abre Safari en la VM de macOS y busca X"* (o *"instala htop en la VM de Ubuntu"*) y que el agente lo logre solo, con la posibilidad de volver atrás con un snapshot.

### Entorno objetivo
- MacBook Pro M1 Max, macOS 26.3, Xcode 26.6.
- Target de despliegue: macOS 26.
- Lenguaje: Swift 6 + SwiftUI.

### Fuera de alcance (MVP)
Windows (requiere hipervisor propio), firma/notarización/distribución, licencias, importar desde Parallels, sonido y micrófono, USB, redirección de puertos (se usa la IP NAT de la VM directamente), un proceso o ícono del Dock por VM.

## 2. Enfoque elegido

App propia sobre `Virtualization.framework` (descartados: envolver `tart` + MCP sobre VNC, y controlar UTM vía `utmctl`/VNC; ambos aprenden poco y dan control menos fino).

## 3. Arquitectura

```
~/XcodeProjects/vmbox
├── VMBox.app          SwiftUI: biblioteca de VMs, ventana por VM, ajustes
├── VMCore (SwiftPM)   ciclo de vida, creación, snapshots, captura y entrada
├── vmbox-mcp          CLI stdio embebido en VMBox.app/Contents/MacOS
└── guest-agent        (fase 4) binario dentro del invitado, vía vsock
```

### 3.1 Paquete de VM
Cada VM es una carpeta `~/Library/Application Support/VMBox/VMs/<nombre>.vmbox/`:
- `config.json` — id (UUID), nombre, SO, CPU, RAM, tamaño de disco, carpetas compartidas, `agentControlEnabled` (bool, por defecto `false`), MAC address.
- `disk.img` — imagen de disco dispersa (sparse); ocupa solo lo usado.
- macOS: `aux.img` (VZMacAuxiliaryStorage), `hardware-model.bin`, `machine-id.bin`.
- Linux: `nvram.bin` (VZEFIVariableStore), `machine-id.bin`.
- `snapshots/<nombre>/` — ver §3.4.

### 3.2 Creación
- **macOS:** descarga el IPSW más reciente compatible vía `VZMacOSRestoreImage.latestSupported` (o un IPSW local), y luego `VZMacOSInstaller` con progreso. La configuración inicial del sistema (Setup Assistant) la hace el usuario la primera vez, o el agente más adelante.
- **Ubuntu:** ISO arm64 de la última LTS (descarga o archivo local), arranque EFI (`VZEFIBootLoader`) con el ISO como dispositivo USB de almacenamiento; el instalador corre en la ventana de la VM y lo completa el usuario.
- Valores por defecto: macOS 4 CPU / 8 GB / 80 GB; Ubuntu 4 CPU / 4 GB / 40 GB.
- Dispositivos: virtio net (NAT), virtio block, gráficos (`VZMacGraphicsDevice` / `VZVirtioGraphicsDevice`), teclado y puntero (Mac trackpad/keyboard en macOS, USB en Linux), entropía, balloon, `VZVirtioSocketDevice` (para la fase 4), VirtioFS para carpetas compartidas.

### 3.3 Ciclo de vida
Estados: `stopped`, `starting`, `running`, `paused`, `stopping`, `error`. Delegado de `VZVirtualMachine` (`guestDidStop`, `didStopWithError`) actualiza el estado. `stop` = `requestStop()` con timeout y luego `stop()` forzado si `force: true`.

### 3.4 Snapshots
- Disco: `clonefile(2)` de APFS (instantáneo, copy-on-write).
- VM encendida: además `saveMachineStateTo(url:)` (VM pausada durante el guardado), restaurable con `restoreMachineStateFrom(url:)`.
- Restaurar: requiere la VM detenida; reemplaza `disk.img` por el clon (también vía `clonefile`).

### 3.5 Control sin permisos
- **Entrada:** se sintetizan `NSEvent` de teclado y mouse y se envían directamente a la `VZVirtualMachineView` dentro del proceso de la app. No se usan eventos globales, así que no hace falta permiso de Accesibilidad y la Mac anfitriona nunca recibe entrada del agente.
- **Pantalla:** captura del contenido de la `VZVirtualMachineView`.
- ⚠️ **Mayor riesgo técnico** — se valida en la Fase 0. Plan B: ScreenCaptureKit filtrado a la ventana propia para captura, y `CGEvent` dirigido al PID propio (`postToPid`) para entrada. Cualquier cambio de enfoque se consulta antes.
- Las VMs solo pueden ser controladas si tienen ventana (la vista existe). Si el agente inicia una VM, la app abre su ventana.

## 4. Interfaz

**Ventana principal (biblioteca):** lista de VMs (nombre, SO, estado, espacio en disco, indicador "agente conectado"); botones Nueva VM, Iniciar, Detener, Snapshots, Configuración.

**Asistente "Nueva VM"** (una hoja, 3 pasos): 1) SO — macOS (última o IPSW propio) / Ubuntu (última LTS o ISO propio); 2) recursos con valores por defecto; 3) nombre y crear, con barra de progreso de descarga/instalación.

**Ventana de VM** (una por VM, mismo proceso): `VZVirtualMachineView` redimensionable (resolución dinámica en macOS); barra con ▶︎ ⏸ ⏹, 📸 snapshot, interruptor **"Permitir control de agente"** (apagado por defecto), banner **"🤖 Agente controlando"** mientras el MCP inyecta entrada. Carpetas compartidas por VirtioFS (en macOS aparecen solas; en Ubuntu se montan con un comando que la UI muestra).

**Ajustes:** ruta de la biblioteca; botón "Copiar comando para Claude Code"; log del MCP con las últimas llamadas.

## 5. MCP y control del agente

### 5.1 Flujo
```
Claude Code ──stdio──▶ vmbox-mcp ──socket Unix (JSON-RPC)──▶ VMBox.app ──▶ VZVirtualMachineView / vsock
```
- `vmbox-mcp` es un traductor: implementa MCP sobre stdio y reenvía cada llamada a la app. Sin lógica de negocio.
- Si la app no corre, `vmbox-mcp` ejecuta `open -a VMBox` y espera el socket (timeout 15 s).
- Socket: `~/Library/Application Support/VMBox/control.sock`, permisos `0600`. Al iniciar, la app borra un socket viejo y lo recrea.
- Registro: `claude mcp add vmbox -- /Applications/VMBox.app/Contents/MacOS/vmbox-mcp`.

### 5.2 Herramientas — Fase 2 (pantalla y entrada)

| Herramienta | Parámetros | Resultado |
|---|---|---|
| `list_vms` | — | nombre, SO, estado, `agentControlEnabled` |
| `start_vm` | `vm` | estado |
| `stop_vm` | `vm`, `force?` | estado |
| `screenshot` | `vm` | PNG (≤1280 px de ancho) + `width`, `height`, `scale` |
| `click` | `vm`, `x`, `y`, `button?` (left/right), `count?` (1/2) | ok |
| `drag` | `vm`, `from_x`, `from_y`, `to_x`, `to_y` | ok |
| `scroll` | `vm`, `x`, `y`, `dx`, `dy` | ok |
| `type_text` | `vm`, `text` | ok |
| `key` | `vm`, `combo` (p. ej. `cmd+space`, `ctrl+c`, `return`) | ok |
| `snapshot_create` | `vm`, `name` | ok |
| `snapshot_list` | `vm` | lista con fecha y si incluye estado de memoria |
| `snapshot_restore` | `vm`, `name`, `confirm: true` | ok |

Coordenadas en el espacio de la **última captura**; la app las convierte a puntos de la vista.

### 5.3 Herramientas — Fase 4 (guest-agent vía vsock)

| Herramienta | Parámetros |
|---|---|
| `run_command` | `vm`, `command`, `timeout_s?` (def. 60), `as_root?` → stdout, stderr, exit code |
| `read_file` / `write_file` | `vm`, `path`, (`content`) |
| `clipboard_get` / `clipboard_set` | `vm`, (`text`) |

### 5.4 Reglas de seguridad
- Toda herramienta salvo `list_vms` falla con `agent_control_disabled` si la VM no tiene activado el control de agente.
- La entrada solo va a la vista de la VM; nunca eventos globales.
- `snapshot_restore` exige `confirm: true` y detiene la VM antes.
- Cada llamada se registra en la UI y en `~/Library/Application Support/VMBox/mcp.log` (rotativo).

## 6. Manejo de errores

- **VM se detiene sola / error:** estado `stopped`/`error` con mensaje en la UI; herramientas devuelven `vm_not_running`.
- **Descargas IPSW/ISO:** reanudables, 3 reintentos, validación de tamaño y SHA256 cuando la fuente lo publica; limpieza de parciales al cancelar.
- **Límite de Apple de 2 VMs macOS simultáneas:** aviso antes de iniciar una tercera.
- **Disco lleno:** verificación de espacio libre antes de crear VM o snapshot.
- **MCP:** errores como resultado de herramienta con `isError: true` y código legible (`agent_control_disabled`, `vm_not_found`, `vm_not_running`, `timeout`, `app_unavailable`, `invalid_argument`); `vmbox-mcp` nunca termina por un error de herramienta.

## 7. Pruebas

- **Unitarias (XCTest, VMCore):** codificación/decodificación de `config.json`; estructura del paquete `.vmbox`; conversión de coordenadas captura→vista; mapeo de texto y combinaciones de teclas a key codes; lógica de snapshots sobre archivos temporales.
- **Protocolo:** `vmbox-mcp` contra una app simulada en el socket — esquema de herramientas, reenvío de llamadas y propagación de errores.
- **Integración (semiautomática):** script con una VM Ubuntu real — iniciar, capturar, escribir en la terminal y verificar, snapshot y restore.
- **Aceptación (manual):** desde Claude Code, "abre Safari en la VM de macOS y busca X".

## 8. Fases

0. **Spike (1–2 días):** confirmar captura del framebuffer de `VZVirtualMachineView` e inyección de eventos sintéticos en la vista, con una VM Ubuntu mínima. Si falla, evaluar el plan B (§3.5) y consultar.
1. **Núcleo:** crear/iniciar/detener VMs Ubuntu y macOS, biblioteca y ventana de VM.
2. **Control de agente:** socket, `vmbox-mcp`, herramientas de pantalla y entrada, interruptor por VM, log.
3. **Snapshots** y carpetas compartidas.
4. **guest-agent** vía vsock: comandos, archivos, portapapeles; instalable para Ubuntu y macOS.
