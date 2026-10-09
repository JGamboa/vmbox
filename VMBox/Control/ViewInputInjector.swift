import AgentControl
import AppKit
import VMCore

@MainActor
struct ViewInputInjector {
    enum Route { case directToView, windowSendEvent, appPostEvent }

    /// Ruta elegida en la Fase 0. Ajustar a la registrada en docs/spikes/2026-10-fase0-resultados.md.
    static let route: Route = .windowSendEvent

    let view: NSView
    var stepDelay: Duration = .milliseconds(20)

    func perform(_ action: InputAction) async {
        switch action {
        case let .click(point, button, count):
            view.window?.makeFirstResponder(view)
            await click(at: point, button: button, count: count)
        case let .drag(from, to): await drag(from: from, to: to)
        case let .scroll(point, dx, dy): await scroll(at: point, dx: dx, dy: dy)
        case let .keys(strokes):
            view.window?.makeFirstResponder(view)
            // Al retirar el control se cancela la Task: se para tras la pulsación en curso (sin dejar teclas apretadas).
            for stroke in strokes {
                if Task.isCancelled { break }
                await press(stroke)
            }
        }
    }

    // MARK: Entrega

    private func deliver(_ event: NSEvent) {
        switch Self.route {
        case .directToView:
            switch event.type {
            case .keyDown: view.keyDown(with: event)
            case .keyUp: view.keyUp(with: event)
            case .flagsChanged: view.flagsChanged(with: event)
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .rightMouseDown: view.rightMouseDown(with: event)
            case .rightMouseUp: view.rightMouseUp(with: event)
            case .mouseMoved: view.mouseMoved(with: event)
            case .scrollWheel: view.scrollWheel(with: event)
            default: break
            }
        case .windowSendEvent: view.window?.sendEvent(event)
        case .appPostEvent: NSApp.postEvent(event, atStart: false)
        }
    }

    private func pause() async { try? await Task.sleep(for: stepDelay) }

    // MARK: Teclado

    private static let modifiers: [(KeyModifiers, NSEvent.ModifierFlags)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command),
    ]

    private func keyEvent(_ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func press(_ stroke: KeyStroke) async {
        let held = Self.modifiers.filter { stroke.modifiers.contains($0.0) }
        var flags: NSEvent.ModifierFlags = []
        for (modifier, flag) in held {
            flags.insert(flag)
            deliver(keyEvent(.flagsChanged, KeyMap.modifierKeyCodes[modifier]!, "", flags))
            await pause()
        }
        if let own = Self.modifiers.first(where: { KeyMap.modifierKeyCodes[$0.0] == stroke.keyCode }) {
            // Modificadora sola (p. ej. "super"): pulsar y soltar.
            deliver(keyEvent(.flagsChanged, stroke.keyCode, "", flags.union(own.1)))
            await pause()
            deliver(keyEvent(.flagsChanged, stroke.keyCode, "", flags))
            await pause()
        } else {
            deliver(keyEvent(.keyDown, stroke.keyCode, stroke.characters, flags))
            await pause()
            deliver(keyEvent(.keyUp, stroke.keyCode, stroke.characters, flags))
            await pause()
        }
        for (modifier, flag) in held.reversed() {
            flags.remove(flag)
            deliver(keyEvent(.flagsChanged, KeyMap.modifierKeyCodes[modifier]!, "", flags))
            await pause()
        }
    }

    // MARK: Mouse (puntos de la vista)

    private func mouseEvent(_ type: NSEvent.EventType, _ point: CGPoint, clickCount: Int = 1) -> NSEvent {
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clickCount, pressure: isUp ? 0 : 1)!
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) async {
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        deliver(mouseEvent(.mouseMoved, point))
        await pause()
        for n in 1...count {
            deliver(mouseEvent(down, point, clickCount: n))
            await pause()
            deliver(mouseEvent(up, point, clickCount: n))
            await pause()
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async {
        deliver(mouseEvent(.mouseMoved, start))
        await pause()
        deliver(mouseEvent(.leftMouseDown, start))
        await pause()
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            deliver(mouseEvent(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            await pause()
        }
        deliver(mouseEvent(.leftMouseUp, end))
        await pause()
    }

    /// dy > 0 desplaza hacia abajo (contenido sube). Si el spike mostró lo contrario, invertir los signos.
    func scroll(at point: CGPoint, dx: Double, dy: Double) async {
        deliver(mouseEvent(.mouseMoved, point))
        await pause()
        guard let window = view.window,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        // El evento viene de un CGEvent sin ventana: se entrega siempre directo a la vista
        // (window.sendEvent haría hit-test con coordenadas de pantalla).
        if let event = NSEvent(cgEvent: cgEvent) { view.scrollWheel(with: event) }
        await pause()
    }
}
