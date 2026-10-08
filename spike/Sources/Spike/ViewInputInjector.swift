import AppKit

enum InputRoute: String, CaseIterable {
    case directToView      // llamar keyDown/mouseDown/... de la vista
    case windowSendEvent   // NSWindow.sendEvent (despacho normal de la ventana)
    case appPostEvent      // NSApp.postEvent (cola de eventos del propio proceso)
    case cgEventToPid      // PLAN B (§3.5): CGEvent.postToPid(getpid()); solo diagnóstico
}

@MainActor
struct ViewInputInjector {
    let view: NSView
    let route: InputRoute
    var stepDelay: Duration = .milliseconds(30)

    // MARK: Entrega

    func deliver(_ event: NSEvent) {
        switch route {
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
        case .windowSendEvent:
            view.window?.sendEvent(event)
        case .appPostEvent:
            NSApp.postEvent(event, atStart: false)
        case .cgEventToPid:
            event.cgEvent?.postToPid(getpid())
        }
    }

    private func pause() async { try? await Task.sleep(for: stepDelay) }

    // MARK: Teclado

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    /// Presiona modificadores (flagsChanged), la tecla (keyDown/keyUp) y suelta modificadores en orden inverso.
    func press(keyCode: UInt16, characters: String, modifiers: [(code: UInt16, flag: NSEvent.ModifierFlags)]) async {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            deliver(keyEvent(.flagsChanged, keyCode: modifier.code, characters: "", flags: flags))
            await pause()
        }
        deliver(keyEvent(.keyDown, keyCode: keyCode, characters: characters, flags: flags))
        await pause()
        deliver(keyEvent(.keyUp, keyCode: keyCode, characters: characters, flags: flags))
        await pause()
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            deliver(keyEvent(.flagsChanged, keyCode: modifier.code, characters: "", flags: flags))
            await pause()
        }
    }

    func type(_ text: String) async {
        for character in text {
            guard let code = SpikeKeys.codes[character] else { continue }
            await press(keyCode: code, characters: character == "\n" ? "\r" : String(character), modifiers: [])
        }
    }

    // MARK: Mouse (puntos en coordenadas de la vista, origen abajo-izquierda)

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) -> NSEvent {
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        return NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: isUp ? 0 : 1
        )!
    }

    func click(at point: NSPoint, right: Bool = false, count: Int = 1) async {
        deliver(mouseEvent(.mouseMoved, at: point))
        await pause()
        for n in 1...count {
            deliver(mouseEvent(right ? .rightMouseDown : .leftMouseDown, at: point, clickCount: n))
            await pause()
            deliver(mouseEvent(right ? .rightMouseUp : .leftMouseUp, at: point, clickCount: n))
            await pause()
        }
    }

    func drag(from start: NSPoint, to end: NSPoint, steps: Int = 12) async {
        deliver(mouseEvent(.mouseMoved, at: start))
        await pause()
        deliver(mouseEvent(.leftMouseDown, at: start))
        await pause()
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            deliver(mouseEvent(.leftMouseDragged, at: p))
            await pause()
        }
        deliver(mouseEvent(.leftMouseUp, at: end))
        await pause()
    }

    func scroll(at point: NSPoint, dx: Int32, dy: Int32) async {
        deliver(mouseEvent(.mouseMoved, at: point))
        await pause()
        guard let window = view.window,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        // CGEvent usa coordenadas globales con origen arriba-izquierda de la pantalla principal.
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        if let event = NSEvent(cgEvent: cgEvent) { deliver(event) }
        await pause()
    }
}
