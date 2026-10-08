# VMBox

**English** · [Español](README.es.md)

VMBox is a macOS app for running **macOS and Ubuntu virtual machines** on Apple silicon, built on Apple's
Virtualization.framework. What sets it apart is that an AI agent can **see and control** the VM. That agent can be
Claude Code, Claude Desktop or any [MCP](https://modelcontextprotocol.io) client. It can take screenshots, click,
type, run commands, copy files and manage snapshots.

- 🖥️ Ubuntu (ARM64) and macOS VMs, each in its own native window.
- 🤖 A built-in MCP server (`vmbox-mcp`) with 17 tools. It is off by default; you enable it per VM.
- 📸 Snapshots of disk and memory, made as instant APFS clones.
- 📁 Shared folders between your Mac and the VM (VirtioFS).
- 🔧 An optional guest agent that runs commands, reads and writes files, and uses the clipboard.

> ⚠️ This is an early-stage project. Use agent control on **disposable VMs only**: an agent that has control can do
> anything a user could do inside the VM.

> 🇪🇸 The app's interface is in Spanish. This guide gives each label as it appears in the app, followed by an
> English translation.

## Contents
- [Requirements](#requirements)
- [Install](#install)
- [Create your first VM](#create-your-first-vm)
- [Connect an AI agent (MCP)](#connect-an-ai-agent-mcp)
- [Snapshots](#snapshots)
- [Shared folders](#shared-folders)
- [Guest agent](#guest-agent-commands-files-clipboard)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Build from source](#build-from-source)
- [License](#license)

## Requirements
- A Mac with **Apple silicon** (M1 or later).
- **macOS 26** or later.
- Free disk space: about 15 GB per Ubuntu VM and about 50 GB per macOS VM.

## Install
1. Download `VMBox.zip` from the latest [release](../../releases/latest) and unzip it.
2. Move `VMBox.app` to `/Applications`.
3. VMBox is **not signed with an Apple Developer ID**, so macOS blocks it the first time you open it. To allow it,
   remove the quarantine flag once from Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/VMBox.app
   ```
   You can instead try to open the app, then go to **System Settings ▸ Privacy & Security** and click
   **Open Anyway**.
4. Open VMBox.

## Create your first VM

### Ubuntu
1. Click **Nueva VM** (New VM, the ＋ button) and choose **Ubuntu**. Under **Origen** (Source), pick the latest LTS,
   which VMBox downloads for you, or your own ARM64 ISO.
2. Choose CPUs, memory and disk size, give the VM a name, and click **Crear** (Create).
3. Start the VM and complete the Ubuntu installer in its window. If you plan to use an agent, **choose the
   English (US) keyboard layout**; see [Limitations](#limitations).
4. When the installer asks you to reboot, stop the VM. Open its **Configuración** (Settings) and turn on
   **Expulsar al guardar** (Eject on save) to remove the ISO. Then click **Guardar** (Save).
5. Start the VM again and log in.

**Performance tips for Ubuntu**
- Give the VM at least **4 CPUs and 8 GB** of memory. Change this in its Settings while it is stopped.
- In Ubuntu, turn off **Settings ▸ Accessibility ▸ Animations**.
- Linux guests have no 3D acceleration under Virtualization.framework. For that reason VMBox gives them a moderate
  fixed resolution instead of full Retina resolution. If you resize the window, the image is scaled.

### macOS
1. Click **Nueva VM** (New VM) and choose **macOS**. Pick the latest compatible restore image (IPSW, about 18 GB to
   download) or your own.
2. Wait for the installation to finish, then complete Setup Assistant in the VM window.
3. Apple allows at most **2 macOS VMs running at the same time** on one Mac.

VMs are stored in `~/Library/Application Support/VMBox/VMs/<name>.vmbox/`. Downloads are kept in
`~/Library/Application Support/VMBox/Cache/`.

## Connect an AI agent (MCP)

### 1. Allow control of the VM
In the VM window, turn on **Permitir control de agente** (Allow agent control). While an agent is acting, the window
shows a "🤖 Agente controlando" (Agent controlling) banner. Turning the switch off cuts access immediately.

### 2. Register the MCP server
The server is the `vmbox-mcp` program inside the app. Keep VMBox open: the server talks to the running app, and
launches it if it is not running.

**Claude Code**: run the command below. You can also copy it from **VMBox ▸ Settings ▸ Copiar comando para Claude
Code** (Copy command for Claude Code).
```bash
claude mcp add --scope user vmbox -- "/Applications/VMBox.app/Contents/MacOS/vmbox-mcp"
```

**Claude Desktop**: add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart
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

**Other MCP clients**: register the same path as a stdio server, with no arguments.

### 3. Try it
Ask your agent something like *"Take a screenshot of the Ubuntu VM"* or *"Open Firefox in the Ubuntu VM and go to
example.com"*.

### Available tools

| Tool | What it does |
|---|---|
| `list_vms` | Lists VMs with their OS, their state, and whether agent control is allowed. |
| `start_vm`, `stop_vm` | Starts or stops a VM. With `force: true`, `stop_vm` powers the VM off if it has not stopped within 30 s. |
| `screenshot` | Returns a PNG of the VM screen, at most 1280 px wide. The input tools use this image's coordinates. |
| `click`, `drag`, `scroll` | Sends mouse input at screenshot coordinates. |
| `type_text` | Types text using a US layout: printable ASCII, `\n` and `\t`. |
| `key` | Presses a key combination such as `ctrl+c`, `ctrl+alt+t`, `cmd+space`, `return` or `f5`. |
| `snapshot_create`, `snapshot_list`, `snapshot_restore` | Manage snapshots. Restoring requires `confirm: true`. |
| `run_command`, `read_file`, `write_file`, `clipboard_get`, `clipboard_set` | Require the [guest agent](#guest-agent-commands-files-clipboard). |

To test the server without an agent, run this from a clone of this repository:
```bash
python3 scripts/mcp_smoke.py /Applications/VMBox.app/Contents/MacOS/vmbox-mcp Ubuntu list screenshot:/tmp/vm.png
```

## Snapshots
- Click 📸 in the VM window, or **Snapshots** in the library.
- If the VM is **running**, the snapshot also saves its memory. Restoring leaves the VM stopped, and the next start
  resumes exactly where it was. Resuming from memory only works while VMBox stays open. If you relaunch the app, the
  VM starts from the restored disk with a normal boot.
- Snapshots are APFS clones: they are created instantly and only use space for the blocks that change afterwards.

## Shared folders
1. Stop the VM, open its **Configuración** (Settings) and go to **Carpetas compartidas** (Shared folders). Add
   folders from your Mac; you can mark each one **Solo lectura** (Read-only).
2. Start the VM. Where the folders appear depends on the guest:
   - **macOS**: in `/Volumes/My Shared Files`.
   - **Ubuntu**: mount them first:
     ```bash
     sudo mkdir -p /mnt/vmbox && sudo mount -t virtiofs vmbox /mnt/vmbox
     ```

## Guest agent (commands, files, clipboard)
The guest agent is a small service that runs inside the VM. With it, an agent can run commands and move files
without using the mouse and keyboard. It talks to VMBox over vsock, so the VM needs no network for this.

1. Stop the VM. In its **Configuración** (Settings), turn on **Compartir el instalador con la VM** (Share the installer
   with the VM). Click **Guardar** (Save) and start the VM.
2. Open a terminal in the VM and run the install command shown in Settings. There is one command for Ubuntu and one
   for macOS.
3. The `run_command`, `read_file`, `write_file`, `clipboard_get` and `clipboard_set` tools now work. If the guest
   agent is not running, they return `guest_agent_unavailable`.

> The installer sets up passwordless `sudo` for your user, which `as_root` needs. Use it only on disposable VMs.

## Troubleshooting
- **macOS says VMBox "is damaged" or "can't be opened"**: run the `xattr` command from [Install](#install).
- **Ubuntu is very slow**: follow the performance tips in [Ubuntu](#ubuntu).
- **The VM window does not appear**: select the VM in the library and click **Abrir ventana** (Open window).
- **The VM is stuck on "Deteniendo" (Stopping)**: the guest is ignoring the shutdown request. Use
  **Forzar apagado** (Force power off) from the stop menu, or `stop_vm` with `force: true`.
- **The agent gets `agent_control_disabled`**: turn on **Permitir control de agente** in the VM window.
- **The agent gets `app_not_running`**: open VMBox.
- **The agent types the wrong symbols**: set the guest keyboard layout to **English (US)**.
- **Other MCP problems**: VMBox ▸ Settings ▸ **Mostrar mcp.log en Finder** (Show mcp.log in Finder).

## Limitations
- VMBox needs Apple silicon, and guests must be ARM64 (Ubuntu ARM64 or macOS).
- Linux guests have no 3D acceleration; this is a Virtualization.framework limitation. macOS guests do get GPU
  acceleration.
- At most 2 macOS VMs can run at the same time; this is Apple's limit.
- `type_text` assumes a US keyboard layout in the guest. For other text, use `clipboard_set` and paste it.
- The app is not signed or notarized; see [Install](#install).
- The interface is in Spanish only for now.

## Build from source
You need Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go 1.26 or later:
```bash
brew install xcodegen go
git clone https://github.com/JGamboa/vmbox.git
cd vmbox
scripts/test.sh          # unit tests (Swift + Go)
scripts/build.sh         # builds build/Build/Products/Debug/VMBox.app
open build/Build/Products/Debug/VMBox.app
```

Project layout:

| Path | Contents |
|---|---|
| `VMBox/` | The SwiftUI app: library, VM window, settings and control host. |
| `Packages/VMCore/` | A Swift package with the VM runtime, control protocol, input and capture, and MCP bridge. |
| `vmbox-mcp/` | The MCP server executable (stdio), which is embedded in the app. |
| `guest-agent/` | The Go guest agent for Ubuntu and macOS, plus its install scripts. |
| `docs/` | The design spec and implementation plans, in Spanish. |

Issues and pull requests are welcome.

## License
[MIT](LICENSE) © 2026 Joaquín Gamboa
