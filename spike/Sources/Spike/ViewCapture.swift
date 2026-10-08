import AppKit
import CoreImage
import ImageIO
import IOSurface
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum ViewCapture {
    /// Estrategias en proceso (plan A). Ninguna necesita permisos.
    enum Strategy: String, CaseIterable {
        case cacheDisplay    // NSView.cacheDisplay(in:to:)
        case layerRender     // CALayer.render(in:)
        case layerIOSurface  // IOSurface que la vista usa como contents de alguna capa
    }

    static func capture(_ view: NSView, using strategy: Strategy) -> CGImage? {
        switch strategy {
        case .cacheDisplay: cacheDisplay(view)
        case .layerRender: layerRender(view)
        case .layerIOSurface: layerIOSurface(view)
        }
    }

    static func cacheDisplay(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func layerRender(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    static func layerIOSurface(_ view: NSView) -> CGImage? {
        guard let root = view.layer, let surface = findSurface(in: root) else { return nil }
        let image = CIImage(ioSurface: surface)
        return CIContext().createCGImage(image, from: image.extent)
    }

    private static func findSurface(in layer: CALayer) -> IOSurface? {
        if let surface = layer.contents as? IOSurface { return surface }
        for sublayer in layer.sublayers ?? [] {
            if let surface = findSurface(in: sublayer) { return surface }
        }
        return nil
    }

    /// Diagnóstico: árbol de capas con clase, tamaño y tipo de `contents`.
    static func describeLayers(_ view: NSView) -> String {
        var lines: [String] = []
        func walk(_ layer: CALayer, depth: Int) {
            let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "nil"
            lines.append("\(String(repeating: "  ", count: depth))\(type(of: layer)) frame=\(layer.frame) contents=\(contents)")
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        lines.append("vista \(type(of: view)) subviews=\(view.subviews.map { String(describing: type(of: $0)) })")
        if let layer = view.layer { walk(layer, depth: 0) } else { lines.append("(sin capa)") }
        return lines.joined(separator: "\n")
    }

    /// Plan B (§3.5), SOLO diagnóstico: captura de la ventana propia con ScreenCaptureKit.
    /// Puede pedir permiso de Grabación de pantalla; anotar si lo pide.
    static func screenCaptureKit(window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ventana propia no encontrada en SCShareableContent"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Luminancia media y desviación estándar sobre una miniatura de 64×64.
    /// Una imagen negra o uniforme tiene stddev ≈ 0.
    static func stats(_ image: CGImage) -> (mean: Double, stddev: Double) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Spike", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Spike", code: 3) }
    }
}
