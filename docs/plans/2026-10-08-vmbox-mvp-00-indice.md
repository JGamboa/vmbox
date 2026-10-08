# VMBox MVP — Plan de implementación (índice)

> **Para agentes:** SUB-SKILL REQUERIDO: usa superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`) para el seguimiento. Cada fase está en su propio archivo; ejecútalas en orden. **La Fase 0 es una compuerta:** no empieces la Fase 1 hasta que el usuario haya revisado los resultados del spike.

**Objetivo:** app nativa de macOS (VMBox) que crea y corre VMs de macOS y Ubuntu sobre Virtualization.framework y expone un servidor MCP (`vmbox-mcp`) para que Claude Code las controle por pantalla, teclado y mouse (Fase 2) y por comandos vía un guest-agent sobre vsock (Fase 4).

**Arquitectura:** un proyecto Xcode generado con XcodeGen contiene la app SwiftUI `VMBox` y la herramienta de línea de comandos `vmbox-mcp` (embebida en `VMBox.app/Contents/MacOS`). Toda la lógica testeable vive en un paquete SwiftPM local `Packages/VMCore` con cuatro bibliotecas: `VMCore` (VMs), `ControlProtocol` (JSON-RPC sobre socket Unix), `AgentControl` (enrutador de herramientas dentro de la app) y `MCPBridge` (servidor MCP que reenvía a la app). El guest-agent es un binario Go que escucha en vsock dentro del invitado.

**Stack:** Swift 6.3 (modo de lenguaje 6) · SwiftUI/AppKit · Virtualization.framework · XCTest · XcodeGen 2.46 · SDK oficial de MCP para Swift `modelcontextprotocol/swift-sdk` 0.12.1 · Go 1.27 (guest-agent) · Xcode 26.6 en macOS 26.3, MacBook Pro M1 Max.

**Spec:** [docs/specs/2026-10-08-vmbox-design.md](../specs/2026-10-08-vmbox-design.md). El plan se apoya en la spec; quien ejecute debe leer ambos.

## Archivos del plan

| Fase | Archivo | Entregable |
|---|---|---|
| 0 | [2026-10-08-vmbox-fase0-spike.md](2026-10-08-vmbox-fase0-spike.md) | Spike: captura de `VZVirtualMachineView` + eventos sintéticos con Ubuntu live. **Compuerta.** |
| 1 | [2026-10-08-vmbox-fase1-nucleo.md](2026-10-08-vmbox-fase1-nucleo.md) | Proyecto, VMCore, crear/iniciar/detener VMs Ubuntu y macOS, biblioteca y ventana de VM |
| 2 | [2026-10-08-vmbox-fase2-control-agente.md](2026-10-08-vmbox-fase2-control-agente.md) | Socket de control, `vmbox-mcp`, herramientas de pantalla y entrada, interruptor, banner y log |
| 3 | [2026-10-08-vmbox-fase3-snapshots-carpetas.md](2026-10-08-vmbox-fase3-snapshots-carpetas.md) | Snapshots (clonefile + estado de memoria) y carpetas compartidas VirtioFS |
| 4 | [2026-10-08-vmbox-fase4-guest-agent.md](2026-10-08-vmbox-fase4-guest-agent.md) | guest-agent Go vía vsock: comandos, archivos, portapapeles; instalable en Ubuntu y macOS |

## Decisiones prácticas (resueltas para este plan)

1. **Proyecto Xcode con XcodeGen.** `project.yml` versionado; `VMBox.xcodeproj` se genera (`xcodegen generate`) y queda en `.gitignore`. Así el proyecto se puede crear, revisar en diffs y reconstruir desde la terminal sin tocar la GUI de Xcode. Se instala con `brew install xcodegen` (no está instalado hoy).
2. **Targets:**
   - `VMBox` (application, macOS 26) — depende de los productos `VMCore`, `ControlProtocol`, `AgentControl`.
   - `vmbox-mcp` (tool) — un `main.swift` que depende de `MCPBridge` y `ControlProtocol`. Se embebe en el app con una fase *Copy Files* de destino `executables` (`Contents/MacOS/vmbox-mcp`), declarada en `project.yml` como dependencia `embed: true, link: false, copy: {destination: executables}`.
   - `Packages/VMCore` (SwiftPM local, `swift-tools-version:6.2`, porque `.macOS(.v26)` requiere PackageDescription 6.2 — verificado).
3. **Entitlement y firma.** `VMBox/VMBox.entitlements` con `com.apple.security.virtualization = true`, firma ad hoc (`CODE_SIGN_IDENTITY = "-"`, sin equipo), sin App Sandbox y sin Hardened Runtime. Es suficiente para correr localmente; firma/notarización están fuera de alcance. El spike de la Fase 0 firma su ejecutable SwiftPM con `codesign --sign - --entitlements`.
4. **Librería MCP: SDK oficial `modelcontextprotocol/swift-sdk`, fijado con `exact: "0.12.1"`.** Evaluado el 2026-10-08: última versión (2026-05-07), unas 1.500 estrellas, soporta macOS 13+, `StdioTransport`, `Server.withMethodHandler(ListTools/CallTool)`, contenido `.image(data:mimeType:annotations:_meta:)` en base64 y `InMemoryTransport.createConnectedPair()` para tests. Probado en un paquete de prueba: compila con Swift 6.3 y un cliente lista y llama herramientas por `InMemoryTransport`. Notas: `.text("…")` y `.image(data:mimeType:)` sin `annotations`/`_meta` están obsoletos (usar las formas completas); `Server.waitUntilCompleted()` mantiene vivo el proceso stdio; trae swift-nio, swift-log y swift-system como dependencias transitivas (aceptable: solo las enlaza `vmbox-mcp`).
5. **Socket de control:** JSON-RPC 2.0 delimitado por saltos de línea sobre `AF_UNIX`, **una conexión por llamada** (conectar, enviar una línea, leer una línea, cerrar). Eso evita multiplexar ids y tolera que la app se reinicie entre llamadas. Implementación POSIX propia (≈200 líneas), testeable con `socketpair(2)`.
6. **guest-agent en Go** (compila cruzado a `linux/arm64` y `darwin/arm64` con `GOOS/GOARCH` y sin toolchains extra; `golang.org/x/sys/unix` tiene `SockaddrVM` en Linux y Darwin). Habla el mismo JSON-RPC por líneas que el socket de control, sobre vsock puerto 7000.
7. **`vmbox-mcp` lanza la app que lo contiene:** si el socket no responde, abre el `.app` tres niveles arriba de su propio ejecutable (sirve tanto para la build de desarrollo como para `/Applications`) y, si no está dentro de un bundle, `open -a VMBox`. Espera el socket hasta 15 s (spec §5.1).

## Comandos (desde la raíz del repo)

```bash
brew install xcodegen
```

```bash
scripts/test.sh
```

```bash
scripts/build.sh
```

```bash
open build/Build/Products/Debug/VMBox.app
```

```bash
claude mcp add vmbox -- "$PWD/build/Build/Products/Debug/VMBox.app/Contents/MacOS/vmbox-mcp"
```

`scripts/build.sh` corre `xcodegen generate` y luego `xcodebuild -project VMBox.xcodeproj -scheme VMBox -configuration Debug -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation build`. `scripts/test.sh` corre `swift test --package-path Packages/VMCore` (y, desde la Fase 4, `go test ./...` en `guest-agent`).

## Estructura final del repositorio

```
vmbox/
├── project.yml                         XcodeGen (VMBox + vmbox-mcp)
├── VMBox/                              app SwiftUI
│   ├── VMBoxApp.swift
│   ├── VMBox.entitlements              (generado por XcodeGen desde project.yml)
│   ├── Model/AppModel.swift            biblioteca, instancias, alertas, ventanas, actividad de agente
│   ├── Model/AgentVMAdapter.swift      (F2) VMInstance + vista → VMControlling
│   ├── Control/ControlHost.swift       (F2) ControlServer + ControlService
│   ├── Control/ViewCapture.swift       (F2) captura elegida en el spike
│   ├── Control/ViewInputInjector.swift (F2) inyección elegida en el spike
│   ├── Control/VsockGuestConnector.swift (F4)
│   └── Views/ LibraryView, NewVMSheet, VMWindowView, VMDisplayView, VMToolbar,
│              VMSettingsSheet, SettingsView (F2), SnapshotsSheet (F3)
├── vmbox-mcp/main.swift                (F2)
├── Packages/VMCore/
│   ├── Package.swift
│   ├── Sources/VMCore/                 Config/ Bundle/ Runtime/ Creation/ Input/ Snapshots/
│   ├── Sources/ControlProtocol/        (F2) JSONValue, mensajes, LineChannel, UnixSocket, server/client, RPC
│   ├── Sources/AgentControl/           (F2) VMControlling, ControlService, MCPLog
│   ├── Sources/MCPBridge/              (F2) ToolCatalog, Bridge, AppLauncher
│   └── Tests/{VMCoreTests,ControlProtocolTests,AgentControlTests,MCPBridgeTests}
├── guest-agent/                        (F4) Go
├── spike/                              (F0) ejecutable SwiftPM desechable
├── scripts/ build.sh test.sh fetch-ubuntu-iso.sh mcp_smoke.py build-guest-agent.sh
└── docs/ specs/ plans/ spikes/
```

## Restricciones globales

Cada tarea las incluye implícitamente. Valores copiados de la spec:

- Target de despliegue **macOS 26**; Swift 6 + SwiftUI; Apple silicon (M1 Max). Solo `Virtualization.framework`.
- Fuera de alcance: **Windows, firma/notarización/distribución, licencias, importar desde Parallels, sonido y micrófono, USB, redirección de puertos, un proceso o ícono del Dock por VM.**
- Paquete de VM: `~/Library/Application Support/VMBox/VMs/<nombre>.vmbox/` con `config.json`, `disk.img` (sparse), macOS: `aux.img`, `hardware-model.bin`, `machine-id.bin`; Linux: `nvram.bin`, `machine-id.bin`; `snapshots/<nombre>/`.
- `config.json`: id (UUID), nombre, SO, CPU, RAM, tamaño de disco, carpetas compartidas, `agentControlEnabled` (**por defecto `false`**), MAC address.
- Valores por defecto: **macOS 4 CPU / 8 GB / 80 GB; Ubuntu 4 CPU / 4 GB / 40 GB.**
- Estados: `stopped`, `starting`, `running`, `paused`, `stopping`, `error`.
- Entrada **solo** a la `VZVirtualMachineView` dentro del proceso; nunca eventos globales; sin permiso de Accesibilidad. **Cualquier cambio de enfoque de captura o entrada (plan B, §3.5) se consulta con el usuario antes.**
- Las VMs solo se controlan si tienen ventana; si el agente inicia una VM, la app abre su ventana.
- Socket `~/Library/Application Support/VMBox/control.sock`, permisos **`0600`**; al iniciar, la app borra un socket viejo y lo recrea.
- `vmbox-mcp` es un traductor sin lógica de negocio; si la app no corre la abre y espera el socket (**timeout 15 s**); **nunca termina por un error de herramienta**.
- `screenshot`: PNG **≤1280 px de ancho** + `width`, `height`, `scale`; coordenadas de `click`/`drag`/`scroll` en el espacio de la **última captura**.
- Toda herramienta salvo `list_vms` falla con `agent_control_disabled` si la VM no tiene el control de agente activado. `snapshot_restore` exige `confirm: true` y detiene la VM antes.
- Códigos de error: `agent_control_disabled`, `vm_not_found`, `vm_not_running`, `timeout`, `app_unavailable`, `invalid_argument` (el plan añade `internal_error` para fallos inesperados y, en la Fase 4, `guest_agent_unavailable`). Errores como resultado de herramienta con `isError: true`.
- Cada llamada se registra en la UI y en `~/Library/Application Support/VMBox/mcp.log` (rotativo).
- Límite de Apple: **2 VMs macOS simultáneas** → aviso antes de iniciar una tercera. Verificar espacio libre antes de crear VM o snapshot.
- Descargas IPSW/ISO: reanudables, **3 reintentos**, validación de tamaño y SHA256 cuando la fuente lo publica, limpieza de parciales al cancelar.
- Dependencia MCP fijada a `exact: "0.12.1"`. Bundle id `cl.multiapi.vmbox`.

## Foco de revisión

Entradas o fallos que la spec implica pero que ninguna prueba "obvia" ejercita. Cada uno tiene su test en la tarea dueña del código:

1. **`type_text` con texto no ASCII** (ñ, tildes, emoji): se espera `invalid_argument` que lista los caracteres no soportados, **sin teclear nada a medias**. → Fase 2, Tarea 2.4 (KeyMap) y Tarea 2.6 (ControlService no llama a `perform`).
2. **Coordenadas fuera de la última captura, negativas o tras redimensionar la ventana:** fuera de rango → `invalid_argument` sin clic; tras redimensionar, el clic cae en el mismo lugar relativo. → Fase 2, Tareas 2.5 y 2.6.
3. **La app no corre, se reinicia a mitad de sesión o hay dos instancias** (build de desarrollo + `/Applications`): `vmbox-mcp` lanza la app y reintenta una vez; un socket viejo se reemplaza; un socket vivo de otra instancia **no** se roba; escribir a un socket cerrado no mata el proceso (SIGPIPE). → Fase 2, Tareas 2.2, 2.3, 2.8 y 2.9.
4. **Descargas interrumpidas y creaciones fallidas:** una descarga cortada se reanuda con `Range`; cancelar borra el `.part`; un SHA256 incorrecto no deja archivo final; una instalación de macOS fallida no deja un `.vmbox` a medias en la biblioteca; si llega menos de lo que el servidor anunció, se reanuda (validación de tamaño, spec §6). → Fase 1, Tareas 1.2, 1.5 y 1.7.
5. **`config.json` editado a mano, antiguo o corrupto, y nombres de VM inválidos:** claves opcionales faltantes toman su valor por defecto (`agentControlEnabled = false`); un paquete corrupto se omite y se informa sin romper la biblioteca; nombres vacíos, con `/` o `:`, o duplicados sin distinguir mayúsculas se rechazan. → Fase 1, Tareas 1.1 y 1.2.

## Riesgos conocidos y dónde se resuelven

- **Captura/entrada de la vista (§3.5):** Fase 0. Si ninguna estrategia en proceso funciona, se detiene el plan y se consulta (plan B = ScreenCaptureKit + `CGEvent.postToPid`, que probablemente pide permisos TCC).
- **Relación de aspecto de la captura vs. la vista:** el mapeo de coordenadas supone que la captura cubre exactamente la vista. El spike lo mide; si no es así, se consulta antes de la Tarea 2.5.
- **vsock en invitados macOS:** se verifica al inicio de la Fase 4 (Tarea 4.2, paso de humo) antes de construir encima.
- **`project.yml` / XcodeGen:** XcodeGen no está instalado en esta Mac, así que la generación del proyecto y el embebido de `vmbox-mcp` en `Contents/MacOS` se validan por primera vez en las Tareas 1.1 y 2.10 (cada una tiene su paso de verificación).

## Verificación del plan (2026-10-08)

Antes de entregar el plan, todo su código se extrajo a un directorio temporal fuera del repo, se aplicaron las modificaciones de cada tarea en orden y se compiló y probó:

- `Packages/VMCore` completo (Fases 1–4): compila con Swift 6.3 en modo de lenguaje 6 y **139 tests XCTest pasan**.
- Código de la app `VMBox` (Fases 1–4) y `vmbox-mcp`, compilados como ejecutables SwiftPM contra el paquete: sin errores ni advertencias (aparte de las de obsolescencia del SDK MCP).
- `vmbox-mcp` real por stdio: `tools/list` devuelve las 9 herramientas de la Fase 2 y una llamada sin la app responde `isError: true` con `app_unavailable` sin terminar el proceso.
- Spike de la Fase 0: compila.
- guest-agent: `go vet` y `go test` en verde; compilación cruzada a `linux/arm64` (ELF estático) y `darwin/arm64` (Mach-O firmado ad hoc).

Lo que **no** se pudo verificar sin ejecutar el plan: todo lo que necesita el entitlement de virtualización o una VM real (arranque, captura, inyección, snapshots de memoria, vsock), XcodeGen/`xcodebuild` y la integración con Claude Code. Esos puntos tienen pasos manuales explícitos en cada fase.

Hallazgos de esa verificación ya corregidos en el plan: `VZVirtualMachineConfiguration.validate()` exige el entitlement en el proceso, así que el builder se separa en `make` (testeable) y `build` (`make` + `validate`, en la app); `readLine` era cuadrático con capturas de varios MB (17 s → 0,01 s con `memchr`); la fecha de los snapshots perdía precisión al pasar por ISO 8601; y el humo de `vmbox-mcp` debe mantener stdin abierto.
