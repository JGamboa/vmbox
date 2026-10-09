# VMBox

[English](README.md) · **Español**

VMBox es una app de macOS para correr **máquinas virtuales de macOS y Ubuntu** en Macs con Apple silicon. Usa
Virtualization.framework, el sistema de virtualización de Apple. Lo que la distingue es que un agente de IA puede
**ver y controlar** la VM. Ese agente puede ser Claude Code, Claude Desktop o cualquier cliente
[MCP](https://modelcontextprotocol.io). Puede sacar capturas de pantalla, hacer clic, escribir, ejecutar comandos,
copiar archivos y administrar snapshots.

- 🖥️ VMs de Ubuntu (ARM64) y macOS, cada una en su propia ventana nativa.
- 🤖 Servidor MCP integrado (`vmbox-mcp`) con 17 herramientas. Viene apagado y se activa en cada VM.
- 📸 Snapshots del disco y de la memoria, hechos como clones APFS instantáneos.
- 📁 Carpetas compartidas entre tu Mac y la VM (VirtioFS).
- 🔧 Guest agent opcional, que ejecuta comandos, lee y escribe archivos y usa el portapapeles.

> ⚠️ Es un proyecto en etapa temprana. Usa el control por agentes **solo en VMs desechables**: un agente con control
> puede hacer dentro de la VM todo lo que haría un usuario.

## Contenido
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Crear tu primera VM](#crear-tu-primera-vm)
- [Conectar un agente de IA (MCP)](#conectar-un-agente-de-ia-mcp)
- [Snapshots](#snapshots)
- [Carpetas compartidas](#carpetas-compartidas)
- [Guest agent](#guest-agent-comandos-archivos-portapapeles)
- [Seguridad: retirar el control de agente](#seguridad-retirar-el-control-de-agente)
- [Solución de problemas](#solución-de-problemas)
- [Limitaciones](#limitaciones)
- [Compilar desde el código](#compilar-desde-el-código)
- [Licencia](#licencia)

## Requisitos
- Un Mac con **Apple silicon** (M1 o posterior).
- **macOS 26** o posterior.
- Espacio libre en disco: unos 15 GB por cada VM de Ubuntu y unos 50 GB por cada VM de macOS.

## Instalación
1. Descarga `VMBox.zip` desde la última [release](../../releases/latest) y descomprímelo.
2. Mueve `VMBox.app` a `/Aplicaciones`.
3. VMBox **no está firmada con un Developer ID de Apple**, así que macOS la bloquea la primera vez que la abres. Para
   permitirla, quítale la cuarentena una vez desde la Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/VMBox.app
   ```
   También puedes intentar abrirla y luego ir a **Ajustes del Sistema ▸ Privacidad y seguridad** y pulsar
   **Abrir igualmente**.
4. Abre VMBox.

## Crear tu primera VM

### Ubuntu
1. Pulsa **Nueva VM** (botón ＋) y elige **Ubuntu**. En **Origen**, elige la última LTS, que VMBox descarga por ti, o tu
   propio ISO ARM64.
2. Elige CPU, memoria y tamaño de disco, ponle un nombre a la VM y pulsa **Crear**.
3. Inicia la VM y completa el instalador de Ubuntu en su ventana. Si vas a usar un agente, **elige el teclado
   Inglés (EE. UU.)**; mira [Limitaciones](#limitaciones).
4. Cuando el instalador pida reiniciar, detén la VM. Abre su **Configuración**, activa **Expulsar al guardar** para
   quitar el ISO y pulsa **Guardar**.
5. Vuelve a iniciar la VM y entra con tu usuario.

**Consejos de rendimiento para Ubuntu**
- Dale a la VM al menos **4 CPU y 8 GB** de memoria. Se cambia en su Configuración con la VM detenida.
- En Ubuntu, desactiva **Configuración ▸ Accesibilidad ▸ Animaciones**.
- Las VMs Linux no tienen aceleración 3D en Virtualization.framework. Por eso VMBox les da una resolución fija
  moderada en vez de la resolución Retina completa. Si cambias el tamaño de la ventana, la imagen se escala.

### macOS
1. Pulsa **Nueva VM** y elige **macOS**. Elige la última imagen de restauración compatible (IPSW, unos 18 GB de
   descarga) o la tuya.
2. Espera a que termine la instalación y completa el Asistente de configuración en la ventana de la VM.
3. Apple permite como máximo **2 VMs de macOS corriendo a la vez** en un mismo Mac.

Las VMs se guardan en `~/Library/Application Support/VMBox/VMs/<nombre>.vmbox/`. Las descargas quedan en
`~/Library/Application Support/VMBox/Cache/`.

## Conectar un agente de IA (MCP)

### 1. Permitir el control de la VM
En la ventana de la VM, activa **Permitir control de agente**. Mientras un agente actúa, la ventana muestra el aviso
"🤖 Agente controlando". Si apagas el interruptor, el acceso se corta de inmediato, se detiene lo que el agente dejó en
marcha y se pausa la VM; las garantías exactas están en [Seguridad](#seguridad-retirar-el-control-de-agente).

### 2. Registrar el servidor MCP
El servidor es el programa `vmbox-mcp`, que viene dentro de la app. Mantén VMBox abierto: el servidor habla con la
app, y la abre si no está corriendo.

**Claude Code**: ejecuta el comando de abajo. También puedes copiarlo desde **VMBox ▸ Ajustes ▸ Copiar comando para
Claude Code**.
```bash
claude mcp add --scope user vmbox -- "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"
```

**Claude Desktop**: agrega esto a `~/Library/Application Support/Claude/claude_desktop_config.json` y reinicia
Claude:
```json
{
  "mcpServers": {
    "vmbox": {
      "command": "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"
    }
  }
}
```

**Otros clientes MCP**: registra la misma ruta como servidor stdio, sin argumentos.

### 3. Pruébalo
Pídele a tu agente algo como *"Saca una captura de la VM Ubuntu"* o *"Abre Firefox en la VM Ubuntu y entra a
example.com"*.

### Herramientas disponibles

| Herramienta | Qué hace |
|---|---|
| `list_vms` | Lista las VMs con su sistema, su estado y si permiten control de agente. |
| `start_vm`, `stop_vm` | Inicia o detiene una VM. Con `force: true`, `stop_vm` la apaga a la fuerza si no se detuvo en 30 s. |
| `screenshot` | Devuelve un PNG de la pantalla de la VM, de 1280 px de ancho como máximo. Las herramientas de entrada usan las coordenadas de esta imagen. |
| `click`, `drag`, `scroll` | Envía acciones del mouse en coordenadas de la captura. |
| `type_text` | Escribe texto con distribución US: ASCII imprimible, `\n` y `\t`. |
| `key` | Pulsa una combinación de teclas, como `ctrl+c`, `ctrl+alt+t`, `cmd+space`, `return` o `f5`. |
| `snapshot_create`, `snapshot_list`, `snapshot_restore` | Administran los snapshots. Restaurar exige `confirm: true`. |
| `run_command`, `read_file`, `write_file`, `clipboard_get`, `clipboard_set` | Requieren el [guest agent](#guest-agent-comandos-archivos-portapapeles). |

Para probar el servidor sin un agente, ejecuta esto desde un clon de este repositorio:
```bash
python3 scripts/mcp_smoke.py /Applications/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu list screenshot:/tmp/vm.png
```

## Snapshots
- Pulsa 📸 en la ventana de la VM, o **Snapshots** en la biblioteca.
- Si la VM está **encendida**, el snapshot también guarda su memoria. Al restaurar, la VM queda detenida, y el
  siguiente inicio continúa exactamente donde estaba. Continuar desde la memoria solo funciona mientras VMBox siga
  abierto. Si vuelves a abrir la app, la VM arranca normalmente desde el disco restaurado.
- Los snapshots son clones APFS: se crean al instante y solo ocupan espacio por los bloques que cambian después.

## Carpetas compartidas
1. Detén la VM, abre su **Configuración** y ve a **Carpetas compartidas**. Agrega carpetas de tu Mac; puedes marcar
   cada una como **Solo lectura**. Si el control de agente está activado, las carpetas nuevas se agregan en solo
   lectura y la Configuración avisa de cualquier carpeta en la que el agente pueda escribir.
2. Inicia la VM. Dónde aparecen las carpetas depende del sistema invitado:
   - **macOS**: en `/Volumes/My Shared Files`.
   - **Ubuntu**: primero hay que montarlas:
     ```bash
     sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox
     ```

## Guest agent (comandos, archivos, portapapeles)
El guest agent es un pequeño servicio que corre dentro de la VM. Con él, un agente puede ejecutar comandos y mover
archivos sin usar el mouse ni el teclado. Se comunica con VMBox por vsock, así que la VM no necesita red para esto.

1. Detén la VM. En su **Configuración**, activa **Compartir el instalador con la VM**. Pulsa **Guardar** e inicia la
   VM.
2. Abre una terminal en la VM y ejecuta el comando de instalación que aparece en la Configuración. Hay un comando para
   Ubuntu y otro para macOS.
3. Ahora funcionan `run_command`, `read_file`, `write_file`, `clipboard_get` y `clipboard_set`. Si el guest agent no
   está corriendo, devuelven `guest_agent_unavailable`.

> El instalador configura `sudo` sin contraseña para tu usuario, algo que `as_root` necesita. Úsalo solo en VMs
> desechables.

## Seguridad: retirar el control de agente
Apagar **Permitir control de agente** falla en cerrado: no solo bloquea las llamadas nuevas, también detiene los
efectos que ya estaban en curso. En este orden:

1. **Se rechazan las llamadas nuevas** con `agent_control_disabled`. El bloqueo vive en memoria, así que se aplica
   aunque no se pueda guardar `config.json`.
2. **Se cortan las llamadas en curso.** Cada una devuelve `agent_control_disabled` al instante, sin esperar a que
   termine su trabajo, y un resultado que llegue después de apagar el interruptor nunca se entrega al agente. Las
   llamadas al invitado cierran su conexión vsock, y el guest agent mata el grupo de procesos del comando que
   ejecutaba esa conexión.
3. **El guest agent mata todo lo que lanzó** (`cancel_all`, con `SIGKILL`): el grupo de procesos de cada comando,
   cualquier proceso que aún descienda del agente y los procesos lanzados con `as_root` (los mata con `sudo -n`). En
   Ubuntu, donde corre como el servicio de usuario de systemd `vmbox-guest-agent.service`, además mata todos los
   procesos del cgroup del servicio, lo que cubre a los que hicieron `setsid` o doble fork para desligarse. Requiere
   el guest agent 0.2.0 o posterior; si instalaste uno anterior, vuelve a ejecutar el comando de instalación.
4. **Se pausa la VM**, lo que congela de golpe todo lo demás, incluidas las escrituras en carpetas compartidas.
   VMBox te avisa de que la pausó y por qué; reanúdala con **Iniciar** cuando quieras. Puedes desactivar la pausa en
   VMBox ▸ Ajustes ▸ **Control de agente**. Si la VM ya estaba pausada, los procesos del agente se matan en cuanto la
   reanudas, antes que nada.

Lo que esto **no** garantiza:
- **No se deshace nada.** Los archivos ya escritos, dentro de la VM o en una carpeta compartida con escritura en tu
  Mac, quedan escritos. Para las carpetas que el agente no debe cambiar, usa **Solo lectura**; VirtioFS lo impone
  desde el anfitrión.
- **Sobreviven a `cancel_all` los procesos fuera del alcance del guest agent**: lo que el agente haya encargado al
  gestor de servicios del invitado (`systemd-run`, `systemctl start`, `launchctl`, `cron`, `at`) y, en invitados
  macOS, también los procesos que se desligaron con `setsid` o doble fork después de que su padre terminara (macOS
  no tiene cgroups). La pausa igualmente los congela; detener la VM o restaurar un snapshot acaba con ellos.
- **La entrada por pantalla ya enviada queda enviada.** `type_text` y `key` se detienen tras la pulsación en curso
  (no queda ninguna tecla apretada); un `click`, `drag` o `scroll` en curso termina, porque cada uno dura bastante
  menos de un segundo.
- Si el guest agent no está instalado o no responde, no hay nada que matar; VMBox te avisa, pausa la VM de todos
  modos y reintenta `cancel_all` al reanudarla.
- Un invitado comprometido puede ignorar `cancel_all`. La pausa la impone el anfitrión y no depende del invitado.

## Solución de problemas
- **macOS dice que VMBox "está dañada" o "no se puede abrir"**: ejecuta el comando `xattr` de
  [Instalación](#instalación).
- **Ubuntu va muy lento**: sigue los consejos de rendimiento de [Ubuntu](#ubuntu).
- **No aparece la ventana de la VM**: selecciona la VM en la biblioteca y pulsa **Abrir ventana**.
- **La VM se queda en "Deteniendo"**: el invitado ignora la orden de apagado. Usa **Forzar apagado** desde el menú
  de detener, o `stop_vm` con `force: true`.
- **El agente recibe `agent_control_disabled`**: activa **Permitir control de agente** en la ventana de la VM.
- **El agente recibe `app_not_running`**: abre VMBox.
- **El agente escribe símbolos equivocados**: pon el teclado del invitado en **Inglés (EE. UU.)**.
- **Otros problemas con el MCP**: VMBox ▸ Ajustes ▸ **Mostrar mcp.log en Finder**.

## Limitaciones
- VMBox necesita Apple silicon, y los invitados deben ser ARM64 (Ubuntu ARM64 o macOS).
- Las VMs Linux no tienen aceleración 3D; es una limitación de Virtualization.framework. Las VMs macOS sí tienen
  aceleración por GPU.
- Pueden correr como máximo 2 VMs de macOS a la vez; es un límite de Apple.
- `type_text` asume teclado US en el invitado. Para otro texto, usa `clipboard_set` y pégalo.
- La app no está firmada ni notarizada; mira [Instalación](#instalación).
- Por ahora la interfaz está solo en español.

## Compilar desde el código
Necesitas Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) y Go 1.26 o posterior:
```bash
brew install xcodegen go
git clone https://github.com/JGamboa/vmbox.git
cd vmbox
scripts/test.sh          # tests unitarios (Swift + Go)
scripts/build.sh         # compila build/Build/Products/Debug/VMBox.app
open build/Build/Products/Debug/VMBox.app
```

Estructura del proyecto:

| Ruta | Contenido |
|---|---|
| `VMBox/` | La app SwiftUI: biblioteca, ventana de la VM, ajustes y servidor de control. |
| `Packages/VMCore/` | Paquete Swift con el motor de VMs, el protocolo de control, entrada y captura, y el puente MCP. |
| `vmbox-mcp/` | El ejecutable del servidor MCP (stdio), que va incluido dentro de la app. |
| `guest-agent/` | El guest agent en Go para Ubuntu y macOS, con sus scripts de instalación. |
| `docs/` | La especificación de diseño y los planes de implementación. |

Los issues y pull requests son bienvenidos.

## Licencia
[MIT](LICENSE) © 2026 Joaquín Gamboa
