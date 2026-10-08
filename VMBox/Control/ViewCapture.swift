import AppKit
import CoreImage
import IOSurface

@MainActor
enum ViewCapture {
    enum Strategy { case cacheDisplay, layerRender, layerIOSurface }

    /// Estrategia elegida en la Fase 0. Ajustar a la registrada en docs/spikes/2026-10-fase0-resultados.md.
    static let chosen: Strategy = .layerIOSurface

    static func capture(_ view: NSView) -> CGImage? {
        switch chosen {
        case .cacheDisplay: cacheDisplay(view)
        case .layerRender: layerRender(view)
        case .layerIOSurface: layerIOSurface(view)
        }
    }

    private static func cacheDisplay(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func layerRender(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private static func layerIOSurface(_ view: NSView) -> CGImage? {
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
}
