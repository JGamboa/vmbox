import ControlProtocol
import MCP

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let properties: [String: Value]
    public let required: [String]
    /// Timeout (s) para la llamada al socket según los argumentos.
    public let timeout: @Sendable ([String: JSONValue]) -> Double

    public var tool: Tool {
        Tool(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ]))
    }
}

public enum ToolCatalog {
    static func string(_ description: String) -> Value { .object(["type": "string", "description": .string(description)]) }
    static func number(_ description: String) -> Value { .object(["type": "number", "description": .string(description)]) }
    static func integer(_ description: String) -> Value { .object(["type": "integer", "description": .string(description)]) }
    static func boolean(_ description: String) -> Value { .object(["type": "boolean", "description": .string(description)]) }
    static func oneOf(_ values: [String], _ description: String) -> Value {
        .object(["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)])
    }
    static func fixed(_ seconds: Double) -> @Sendable ([String: JSONValue]) -> Double { { _ in seconds } }

    static let vm = string("VM name (or UUID) as returned by list_vms")
    static let x = number("X in pixels of the latest screenshot (origin top-left)")
    static let y = number("Y in pixels of the latest screenshot (origin top-left)")

    public static let specs: [ToolSpec] = [
        ToolSpec(name: "list_vms", description: "List VMs with name, os, state and agentControlEnabled.",
                 properties: [:], required: [], timeout: fixed(10)),
        ToolSpec(name: "start_vm", description: "Start a VM (VMBox opens its window). Returns the new state.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(120)),
        ToolSpec(name: "stop_vm", description: "Ask the guest to shut down; with force=true, power it off if it does not stop within 30 s.",
                 properties: ["vm": vm, "force": boolean("Force power off after the timeout")], required: ["vm"], timeout: fixed(75)),
        ToolSpec(name: "screenshot",
                 description: "Capture the VM screen as a PNG at most 1280 px wide. click/drag/scroll coordinates use this image's pixel space.",
                 properties: ["vm": vm], required: ["vm"], timeout: fixed(30)),
        ToolSpec(name: "click", description: "Click at (x, y) of the latest screenshot.",
                 properties: ["vm": vm, "x": x, "y": y, "button": oneOf(["left", "right"], "Mouse button (default left)"),
                              "count": integer("1 = click, 2 = double click (default 1)")],
                 required: ["vm", "x", "y"], timeout: fixed(30)),
        ToolSpec(name: "drag", description: "Press at (from_x, from_y), drag to (to_x, to_y) and release.",
                 properties: ["vm": vm, "from_x": x, "from_y": y, "to_x": x, "to_y": y],
                 required: ["vm", "from_x", "from_y", "to_x", "to_y"], timeout: fixed(30)),
        ToolSpec(name: "scroll", description: "Scroll at (x, y). dy > 0 scrolls down, dx > 0 scrolls right (pixels).",
                 properties: ["vm": vm, "x": x, "y": y, "dx": number("Horizontal pixels"), "dy": number("Vertical pixels")],
                 required: ["vm", "x", "y", "dx", "dy"], timeout: fixed(30)),
        ToolSpec(name: "type_text",
                 description: "Type text with a US keyboard layout. Supports printable ASCII, \\n and \\t; other characters are rejected.",
                 properties: ["vm": vm, "text": string("Text to type")], required: ["vm", "text"],
                 timeout: { args in 30 + Double(args["text"]?.stringValue?.count ?? 0) * 0.05 }),
        ToolSpec(name: "key", description: "Press a key combination, e.g. cmd+space, ctrl+c, ctrl+alt+t, return, shift+tab, super, f5.",
                 properties: ["vm": vm, "combo": string("Modifiers and key joined by +")], required: ["vm", "combo"], timeout: fixed(30)),
    ]

    public static var tools: [Tool] { specs.map(\.tool) }

    public static func spec(named name: String) -> ToolSpec? { specs.first { $0.name == name } }
}
