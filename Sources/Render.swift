import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - Cursores

struct CursorArt: @unchecked Sendable {
    let image: CGImage
    let hot: CGPoint      // hotspot em px da imagem, a partir do topo
    let pxPerPoint: Double
}

/// Estilos de seta (desenhados aqui; o estilo 0 usa os cursores reais gravados)
enum CursorStyles {
    static let names = ["Sistema", "Branca", "Preta", "Contorno", "Laranja", "Arco-íris", "Aurora", "Menta", "Ouro", "Neon", "Mão", "Ponteiro"]

    /// Seta clássica em pontos, origem no topo (ponta em 0,0)
    private static let arrow: [CGPoint] = [(0, 0), (0, 16), (4, 12.5), (6.6, 18.6), (8.9, 17.6), (6.4, 11.7), (11.4, 11.7)].map { CGPoint(x: $0.0, y: $0.1) }
    private static let pointer: [CGPoint] = [(0, 0), (13, 5.5), (6.5, 7.2), (4.8, 13.5)].map { CGPoint(x: $0.0, y: $0.1) }

    private static func rgb(_ h: UInt32) -> CGColor {
        CGColor(srgbRed: Double(h >> 16 & 255) / 255, green: Double(h >> 8 & 255) / 255, blue: Double(h & 255) / 255, alpha: 1)
    }

    @MainActor static func art(_ style: Int) -> CursorArt {
        switch style {
        case 0: return system(NSCursor.arrow)
        case 10: return system(NSCursor.pointingHand)
        case 1: return draw(arrow, fill: [rgb(0xFFFFFF)], stroke: rgb(0x000000), width: 1.1)
        case 2: return draw(arrow, fill: [rgb(0x111111)], stroke: rgb(0xFFFFFF), width: 1.4)
        case 3: return draw(arrow, fill: [rgb(0xFFFFFF)], stroke: rgb(0x222222), width: 0.7)
        case 4: return draw(arrow, fill: [rgb(0xFFA23C), rgb(0xFF3B3B)], stroke: rgb(0xFFFFFF), width: 1.3)
        case 5: return draw(arrow, fill: [rgb(0xFF3B6B), rgb(0xFFC23C), rgb(0x3CD87A), rgb(0x3C8BFF), rgb(0xA35CFF)], stroke: rgb(0xFFFFFF), width: 1.3)
        case 6: return draw(arrow, fill: [rgb(0xB18CFF), rgb(0x5BE1FF)], stroke: rgb(0xFFFFFF), width: 1.3)
        case 7: return draw(arrow, fill: [rgb(0x5BF0B0), rgb(0x16B5A0)], stroke: rgb(0xFFFFFF), width: 1.3)
        case 8: return draw(arrow, fill: [rgb(0xFFE066), rgb(0xFF9F1C)], stroke: rgb(0x3A2A00), width: 0.9, glow: rgb(0xFFC83C))
        case 9: return draw(arrow, fill: [rgb(0xFF4FD8), rgb(0x8B5CFF)], stroke: rgb(0xFFFFFF), width: 1.3, glow: rgb(0xFF4FD8))
        default: return draw(pointer, fill: [rgb(0x2B2F3A)], stroke: rgb(0xFFFFFF), width: 1.4)
        }
    }

    @MainActor static func system(_ c: NSCursor) -> CursorArt {
        let size = c.image.size, k = 4.0
        let rep = bitmap(Int(size.width * k), Int(size.height * k))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        c.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return CursorArt(image: rep.cgImage!, hot: CGPoint(x: c.hotSpot.x * k, y: c.hotSpot.y * k), pxPerPoint: k)
    }

    private static func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private static func draw(_ poly: [CGPoint], fill: [CGColor], stroke: CGColor, width: Double, glow: CGColor? = nil) -> CursorArt {
        let k = 4.0, m = 4.0 // px por ponto, margem em pontos
        let bw = (poly.map(\.x).max()! + 2 * m), bh = (poly.map(\.y).max()! + 2 * m)
        let ctx = CGContext(data: nil, width: Int(bw * k), height: Int(bh * k), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: m, y: bh - m); ctx.scaleBy(x: 1, y: -1) // origem no topo
        let path = CGMutablePath(); path.addLines(between: poly); path.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: glow == nil ? 2 : 5, color: glow ?? CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path); ctx.setFillColor(stroke); ctx.setStrokeColor(stroke); ctx.setLineWidth(width * 2); ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(path); ctx.clip()
        if fill.count == 1 { ctx.setFillColor(fill[0]); ctx.fill(path.boundingBox) }
        else {
            let g = CGGradient(colorsSpace: nil, colors: fill as CFArray, locations: nil)!
            let b = path.boundingBox
            ctx.drawLinearGradient(g, start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.maxX, y: b.maxY), options: [])
        }
        return CursorArt(image: ctx.makeImage()!, hot: CGPoint(x: m * k, y: m * k), pxPerPoint: k)
    }

    /// Cursores reais gravados (seta, mãozinha, texto…) a partir da pasta do projeto
    static func recorded(_ ev: Events, dir: URL) -> [CursorArt?] {
        (ev.cursors ?? []).map { s in
            guard let src = CGImageSourceCreateWithURL(dir.appending(path: "cursors/\(s.file)") as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let k = Double(img.width) / s.width
            return CursorArt(image: img, hot: CGPoint(x: s.hotX * k, y: s.hotY * k), pxPerPoint: k)
        }
    }
}

// MARK: - Efeitos de clique (desenhados por quadro)

private func clickImage(_ st: Settings, q: Double, r: Double) -> CGImage? {
    let e = st.click
    let side = Int(r * 5), c = Double(side) / 2
    guard side > 4, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // cor, opacidade e tamanho escolhidos (FocuSee: #DDDDDD, 0,8, 50); arco-íris gira o matiz durante o efeito
    let base = st.clickRainbow ? NSColor(hue: q, saturation: 0.75, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        : NSColor(srgbRed: st.clickColor.r, green: st.clickColor.g, blue: st.clickColor.b, alpha: 1)
    let white = { (a: Double) in CGColor(srgbRed: base.redComponent, green: base.greenComponent, blue: base.blueComponent, alpha: a * st.clickOpacity) }
    func ring(_ rad: Double, _ w: Double, _ color: CGColor) {
        ctx.setStrokeColor(color); ctx.setLineWidth(w)
        ctx.strokeEllipse(in: CGRect(x: c - rad, y: c - rad, width: 2 * rad, height: 2 * rad))
    }
    switch e {
    case .regular:
        let rad = r * (0.55 + 0.5 * q)
        let g = CGGradient(colorsSpace: nil, colors: [white(0.6 * (1 - q)), white(0.35 * (1 - q)), white(0)] as CFArray, locations: [0, 0.75, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: rad, options: [])
    case .collapse:
        ring(r * (1.5 - 1.1 * q), r * 0.14, white(0.9 * (1 - q * q)))
    case .ripple:
        for k in 0..<3 {
            let p = q * 1.5 - Double(k) * 0.25
            if p > 0 && p < 1 { ring(r * (0.3 + 1.6 * p), r * 0.08, white(0.7 * (1 - p))) }
        }
    case .ring:
        ring(r * (0.4 + 1.2 * q), r * 0.12, white(1 - q))
    case .diffusion:
        let rad = r * (0.5 + 1.6 * q)
        let g = CGGradient(colorsSpace: nil, colors: [white(0.9 * (1 - q)), white(0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: rad, options: [])
    case .sparkle:
        ctx.setStrokeColor(white(1 - q)); ctx.setLineWidth(r * 0.12); ctx.setLineCap(.round)
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 + .pi / 8
            let r0 = r * (0.55 + 0.7 * q), r1 = r * (0.95 + 1.0 * q)
            ctx.move(to: CGPoint(x: c + cos(a) * r0, y: c + sin(a) * r0)); ctx.addLine(to: CGPoint(x: c + cos(a) * r1, y: c + sin(a) * r1))
        }
        ctx.strokePath()
    case .firework:
        let cols: [(Double, Double, Double)] = [(1, 0.4, 0.6), (0.35, 0.6, 1), (1, 0.8, 0.3), (0.4, 0.9, 0.6), (1, 0.55, 0.25), (0.7, 0.45, 1)]
        for i in 0..<12 {
            let a = Double(i) * .pi / 6 + (i % 2 == 0 ? 0 : 0.2)
            let d = r * (0.3 + (i % 2 == 0 ? 1.8 : 1.3) * q), dr = r * 0.13 * (1 - 0.5 * q)
            let col = cols[i % cols.count]
            ctx.setFillColor(CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 1 - q))
            ctx.fillEllipse(in: CGRect(x: c + cos(a) * d - dr, y: c + sin(a) * d - dr, width: 2 * dr, height: 2 * dr))
        }
    case .none, .spotlight:
        return nil
    }
    return ctx.makeImage()
}

// MARK: - Anotações e teclas (desenhadas por quadro)

private func sRGBContext(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

private func cg(_ c: RGBA, _ a: Double = 1) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * a) }

private func textLine(_ s: String, size: Double, bold: Bool, color: CGColor) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
}

/// Desenha uma anotação entre p0 e p1 (px do quadro, y para cima); devolve a imagem e onde colocá-la
private func overlayImage(_ ov: Overlay, _ p0: CGPoint, _ p1: CGPoint, lineWidth lw: Double, alpha: Double) -> (CGImage, CGPoint)? {
    let box = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    let m = lw * 5 + 4
    let r = box.insetBy(dx: -m, dy: -m).integral
    guard r.width > 2, r.height > 2, r.width * r.height < 40_000_000, let ctx = sRGBContext(Int(r.width), Int(r.height)) else { return nil }
    ctx.translateBy(x: -r.minX, y: -r.minY)
    ctx.setAlpha(alpha)
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(cg(ov.color)); ctx.setFillColor(cg(ov.color))
    switch ov.kind {
    case .rect:
        let rad = min(ov.radius * min(box.width, box.height) / 2, min(box.width, box.height) / 2)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.strokePath()
    case .oval:
        ctx.strokeEllipse(in: box)
    case .line:
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
    case .arrow:
        let ang = atan2(p1.y - p0.y, p1.x - p0.x), head = lw * 4
        let base = CGPoint(x: p1.x - cos(ang) * head * 0.8, y: p1.y - sin(ang) * head * 0.8)
        ctx.move(to: p0); ctx.addLine(to: base); ctx.strokePath()
        ctx.move(to: p1)
        ctx.addLine(to: CGPoint(x: p1.x - cos(ang - 0.45) * head, y: p1.y - sin(ang - 0.45) * head))
        ctx.addLine(to: CGPoint(x: p1.x - cos(ang + 0.45) * head, y: p1.y - sin(ang + 0.45) * head))
        ctx.closePath(); ctx.fillPath()
    case .text:
        var size = max(6, box.height * 0.6)
        var line = textLine(ov.text, size: size, bold: ov.bold, color: cg(ov.color))
        let w0 = CTLineGetTypographicBounds(line, nil, nil, nil)
        if w0 > box.width * 0.92, w0 > 0 { size *= box.width * 0.92 / w0; line = textLine(ov.text, size: size, bold: ov.bold, color: cg(ov.color)) }
        if ov.background.a > 0 {
            let rad = ov.radius * box.height / 2
            ctx.setFillColor(cg(ov.background))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.fillPath()
        }
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &asc, &desc, nil)
        ctx.textPosition = CGPoint(x: box.midX - w / 2, y: box.midY - (asc - desc) / 2)
        CTLineDraw(line, ctx)
    case .mosaic, .camFull, .camNone:
        return nil
    }
    return ctx.makeImage().map { ($0, r.origin) }
}

/// Pílula das teclas de atalho
private func keyPill(_ s: String, size: Double, color: RGBA, background: RGBA) -> CGImage? {
    guard !s.isEmpty else { return nil }
    let line = textLine(s, size: size, bold: true, color: cg(color))
    var asc: CGFloat = 0, desc: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &asc, &desc, nil)
    let padX = size * 0.8, h = (asc + desc) + size * 0.9
    guard let ctx = sRGBContext(Int(w + padX * 2), Int(h)) else { return nil }
    let r = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
    ctx.setFillColor(cg(background))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: h * 0.3, cornerHeight: h * 0.3, transform: nil)); ctx.fillPath()
    ctx.textPosition = CGPoint(x: padX, y: (h - (asc - desc)) / 2)
    CTLineDraw(line, ctx)
    return ctx.makeImage()
}

private func masked(_ img: CIImage, _ mask: CIImage) -> CIImage {
    let b = CIFilter.blendWithMask()
    b.inputImage = img; b.backgroundImage = CIImage.empty(); b.maskImage = mask
    return b.outputImage!
}

/// Imagens de fundo decodificadas uma vez só
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private var items: [String: CIImage] = [:]
    private let lock = NSLock()
    func image(_ path: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let i = items[path] { return i }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 3840] as CFDictionary)
        else { return nil }
        let i = CIImage(cgImage: cg)
        items[path] = i
        return i
    }
}

// MARK: - Quadro final

/// Desenha um quadro final: fundo + tela com zoom + cursor + efeitos + câmera.
/// Câmera e cursor seguem molas (mesma física do FocuSee), pré-calculadas em 120 Hz.
struct FrameRenderer: @unchecked Sendable {
    let st: Settings
    let ev: Events
    let style: CursorArt
    let shapes: [CursorArt?]
    let src: CGSize      // tamanho da tela já recortada
    let cropPx: CGRect?  // recorte em pixels da gravação (CoreImage: y para cima)
    let out: CGSize
    let content: CGRect
    let base: CIImage
    let mask: CIImage
    let bgOnly: CIImage      // fundo sem sombra nem borda (o zoom 3D desenha a sua sombra)
    let cornerRadius: Double

    private static let hz = 120.0
    private let camZ: [Double], camX: [Double], camY: [Double]
    private let rot3X: [Double], rot3Y: [Double], rot3Z: [Double], fov3: [Double] // zoom 3D (graus), com a mola da tela
    private let curX: [Double], curY: [Double], idle: [Double], velX: [Double], velY: [Double]
    private let maxScale: Double
    private let keyRuns: [(a: Double, b: Double, text: String)]

    /// O que aparece na tela a cada momento: a última combinação (ou o texto digitado, se "Tecla Única" estiver ligada)
    private static func keyRuns(_ keys: [KeyPress], single: Bool) -> [(a: Double, b: Double, text: String)] {
        let hold = 1.5
        var out: [(a: Double, b: Double, text: String)] = []
        var typed = "", lastT = -10.0
        for k in keys where k.combo || single {
            if k.combo { typed = ""; out.append((k.t, k.t + hold, k.s)) }
            else {
                if k.t - lastT > 1.2 { typed = "" }
                typed += k.s.count == 1 ? k.s : " \(k.s) "
                if typed.count > 28 { typed = "…" + typed.suffix(27) }
                out.append((k.t, k.t + hold, typed.trimmingCharacters(in: .whitespaces)))
            }
            lastT = k.t
            if out.count > 1 { out[out.count - 2].b = min(out[out.count - 2].b, k.t) }
        }
        return out
    }

    init(settings st: Settings, events ev: Events, style: CursorArt, shapes: [CursorArt?], src full: CGSize, shortSide: Double, duration: Double) {
        let c = st.cropRect
        let src = CGSize(width: (full.width * c.width).rounded(), height: (full.height * c.height).rounded())
        cropPx = st.crop == nil ? nil : CGRect(x: (c.minX * full.width).rounded(), y: ((1 - c.maxY) * full.height).rounded(), width: src.width, height: src.height)
        self.st = st; self.ev = ev; self.style = style; self.shapes = shapes; self.src = src
        let ratio = st.aspect.ratio ?? src.width / src.height
        var w = ratio >= 1 ? shortSide * ratio : shortSide, h = ratio >= 1 ? shortSide : shortSide / ratio
        let cap = 4096.0 / max(w, h) // limite do H.264
        if cap < 1 { w *= cap; h *= cap }
        out = CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
        let outRect = CGRect(origin: .zero, size: out), unit = min(out.width, out.height)
        let border = st.inset * unit * 0.03
        let avail = outRect.insetBy(dx: st.padding * unit + border, dy: st.padding * unit + border)
        let k = min(avail.width / src.width, avail.height / src.height)
        content = CGRect(x: outRect.midX - src.width * k / 2, y: outRect.midY - src.height * k / 2, width: src.width * k, height: src.height * k)

        // fundo
        var bg: CIImage
        switch st.bgKind {
        case .color:
            bg = CIImage(color: st.color.ci)
        case .wallpaper, .image:
            if let p = st.imagePath, let img = ImageCache.shared.image(p) {
                let s = max(out.width / img.extent.width, out.height / img.extent.height)
                let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                bg = scaled.transformed(by: CGAffineTransform(translationX: (out.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                              y: (out.height - scaled.extent.height) / 2 - scaled.extent.minY))
            } else { bg = CIImage(color: st.color.ci) }
        case .gradient:
            let (c0, c1) = Settings.gradients[st.gradient % Settings.gradients.count]
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: 0, y: out.height); g.point1 = CGPoint(x: out.width, y: 0)
            g.color0 = c0.ci; g.color1 = c1.ci
            bg = g.outputImage!
        }
        if st.blur > 0 { bg = bg.clampedToExtent().applyingGaussianBlur(sigma: st.blur * unit * 0.04) }
        bg = bg.cropped(to: outRect)
        bgOnly = bg

        let radius = st.round * min(content.width, content.height) * 0.5
        cornerRadius = radius
        let r = CIFilter.roundedRectangleGenerator()
        r.extent = content; r.radius = Float(radius); r.color = .white
        mask = r.outputImage!
        var under = bg
        if st.shadow > 0 {
            let shadow = masked(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: st.shadow)).cropped(to: content), mask)
                .applyingGaussianBlur(sigma: unit * 0.025)
                .transformed(by: CGAffineTransform(translationX: 0, y: -unit * 0.01))
            under = shadow.composited(over: under)
        }
        if border > 0 {
            let b = CIFilter.roundedRectangleGenerator()
            b.extent = content.insetBy(dx: -border, dy: -border); b.radius = Float(radius + border); b.color = st.insetColor.ci
            under = b.outputImage!.composited(over: under)
        }
        base = under.cropped(to: outRect)

        // molas: cursor (FocuSee: rigidez 470, amortecimento 70, massa 3) e câmera (conforme Motion)
        let n = Int(duration * Self.hz) + 2, dt = 1 / Self.hz
        var cx = [Double](repeating: 0.5, count: n), cy = cx, zz = [Double](repeating: 1, count: n), zx = cx, zy = cx, idl = [Double](repeating: 0, count: n)
        let s = ev.samples
        var j = 0
        // coordenadas normalizadas da gravação -> da área recortada
        func crop(_ x: Double, _ y: Double) -> (Double, Double) { ((x - c.minX) / c.width, (y - c.minY) / c.height) }
        func target(_ t: Double) -> (Double, Double) {
            guard !s.isEmpty else { return (0.5, 0.5) }
            while j + 1 < s.count && s[j + 1].t <= t { j += 1 }
            if j + 1 >= s.count || t <= s[j].t { return crop(s[j].x, s[j].y) }
            let f = (t - s[j].t) / (s[j + 1].t - s[j].t)
            return crop(s[j].x + (s[j + 1].x - s[j].x) * f, s[j].y + (s[j + 1].y - s[j].y) * f)
        }
        let cs = st.cursorMotion.spring ?? st.cursorSpring, ss = st.motion.spring
        // "Voltar ao início": nos últimos segundos o cursor desliza até onde começou
        let endT = st.clips.last?.b ?? duration, home = target(0)
        func goal(_ t: Double) -> (Double, Double) {
            let tg = target(t)
            guard st.endReturn, st.endDuration > 0, t > endT - st.endDuration else { return tg }
            let f = min(1, (t - (endT - st.endDuration)) / st.endDuration), e = f * f * (3 - 2 * f)
            return (tg.0 + (home.0 - tg.0) * e, tg.1 + (home.1 - tg.1) * e)
        }
        var vx = [Double](repeating: 0, count: n), vy = vx
        var r3 = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3), f3 = [Double](repeating: 35, count: n)
        var rot = (0.0, 0.0, 0.0), rv = (0.0, 0.0, 0.0), fov = 35.0
        var p = target(0), v = (0.0, 0.0), last = p, lastMove = 0.0
        var cam = (1.0, p.0, p.1), cv = (0.0, 0.0, 0.0)
        // zoom ao digitar: nos trechos de digitação a câmera segue o cursor de texto (FocuSee: "mouse path rebuilt")
        let carets = (ev.keys ?? []).compactMap { k in k.x.flatMap { x in k.y.map { (k.t, x, $0) } } }
        let typing = st.typingZoom && !carets.isEmpty ? Settings.typingRanges(ev.keys ?? []).map { ($0.0 - 0.5, $0.1) } : []
        func caret(_ t: Double) -> (Double, Double)? {
            guard typing.contains(where: { t >= $0.0 && t <= $0.1 }) else { return nil }
            let k = carets.lastIndex { $0.0 <= t }
            let nx = k.map { $0 + 1 < carets.count ? $0 + 1 : $0 } ?? 0
            let a = carets[k ?? nx], b = carets[nx]
            if b.0 > a.0, b.0 - a.0 <= 1.5, t > a.0 {
                let f = (t - a.0) / (b.0 - a.0)
                return crop(a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
            }
            let near = abs(t - a.0) <= abs(b.0 - t) ? a : b
            return crop(near.1, near.2)
        }
        var zi = 0
        let zooms = st.zooms.filter { $0.off != true }.sorted { $0.a < $1.a }
        for i in 0..<n {
            let t = Double(i) * dt
            let tg = goal(t)
            if abs(tg.0 - last.0) + abs(tg.1 - last.1) > 0.0005 { lastMove = t; last = tg }
            let prev = p
            if st.smoothCursor {
                let ax = (-cs.stiffness * (p.0 - tg.0) - cs.damping * v.0) / cs.mass
                let ay = (-cs.stiffness * (p.1 - tg.1) - cs.damping * v.1) / cs.mass
                v = (v.0 + ax * dt, v.1 + ay * dt); p = (p.0 + v.0 * dt, p.1 + v.1 * dt)
            } else { p = tg }
            cx[i] = p.0; cy[i] = p.1; idl[i] = t - lastMove
            if i > 0 { vx[i] = (p.0 - prev.0) / dt; vy[i] = (p.1 - prev.1) / dt }
            while zi < zooms.count && zooms[zi].b < t { zi += 1 }
            let zc = zi < zooms.count && zooms[zi].a <= t ? zooms[zi] : nil
            let fc = zc?.focus.map { crop($0[0], $0[1]) }
            let ct = zc != nil && fc == nil ? caret(t) : nil
            let tz = (zc?.scale ?? 1, fc?.0 ?? ct?.0 ?? p.0, fc?.1 ?? ct?.1 ?? p.1)
            let a0 = (-ss.stiffness * (cam.0 - tz.0) - ss.damping * cv.0) / ss.mass
            let a1 = (-ss.stiffness * (cam.1 - tz.1) - ss.damping * cv.1) / ss.mass
            let a2 = (-ss.stiffness * (cam.2 - tz.2) - ss.damping * cv.2) / ss.mass
            cv = (cv.0 + a0 * dt, cv.1 + a1 * dt, cv.2 + a2 * dt)
            cam = (max(1, cam.0 + cv.0 * dt), cam.1 + cv.1 * dt, cam.2 + cv.2 * dt)
            zz[i] = cam.0; zx[i] = cam.1; zy[i] = cam.2
            // zoom 3D: inclinação do bloco (automática pelo ponto de foco, ou manual); fora dele volta a 0
            var tr = (0.0, 0.0, 0.0)
            if let zc, zc.d3 == true {
                let m3 = zc.manual3D ?? {
                    let f = zc.focus.map { crop($0[0], $0[1]) } ?? target(zc.a)
                    return Zoom3D.auto(x: f.0, y: f.1, effect: zc.effect ?? 1)
                }()
                tr = (m3[0], m3[1], m3[2]); fov = m3[3]
            }
            let b0 = (-ss.stiffness * (rot.0 - tr.0) - ss.damping * rv.0) / ss.mass
            let b1 = (-ss.stiffness * (rot.1 - tr.1) - ss.damping * rv.1) / ss.mass
            let b2 = (-ss.stiffness * (rot.2 - tr.2) - ss.damping * rv.2) / ss.mass
            rv = (rv.0 + b0 * dt, rv.1 + b1 * dt, rv.2 + b2 * dt)
            rot = (rot.0 + rv.0 * dt, rot.1 + rv.1 * dt, rot.2 + rv.2 * dt)
            r3[0][i] = rot.0; r3[1][i] = rot.1; r3[2][i] = rot.2; f3[i] = fov
        }
        curX = cx; curY = cy; idle = idl; velX = vx; velY = vy; camZ = zz; camX = zx; camY = zy
        rot3X = r3[0]; rot3Y = r3[1]; rot3Z = r3[2]; fov3 = f3
        keyRuns = Self.keyRuns(ev.keys ?? [], single: st.keysSingle)
        maxScale = max(1.01, st.zooms.map(\.scale).max() ?? st.zoomLevel)
    }

    private func at(_ a: [Double], _ t: Double) -> Double {
        let f = max(0, t * Self.hz), i = min(Int(f), a.count - 2)
        let w = min(f - Double(i), 1)
        return a[i] + (a[i + 1] - a[i]) * w
    }

    private func cursorIndex(_ t: Double) -> Int? {
        let s = ev.samples
        guard !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if s[m].t <= t { lo = m } else { hi = m - 1 } }
        return s[lo].c
    }

    /// Px da tela gravada (y para cima) -> px do quadro final no tempo t, com o zoom da câmera
    func screenTransform(_ t: Double) -> CGAffineTransform {
        let W = src.width, H = src.height, inner = content.width / W
        let z = at(camZ, t), vw = 1 / z
        let cx = min(max(at(camX, t), vw / 2), 1 - vw / 2), cy = min(max(at(camY, t), vw / 2), 1 - vw / 2)
        return CGAffineTransform(translationX: -(cx - vw / 2) * W, y: -(1 - cy - vw / 2) * H) // CoreImage: y para cima
            .concatenating(CGAffineTransform(scaleX: z * inner, y: z * inner))
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
    }

    func frame(_ t: Double, screen: CIImage, camera: CIImage?) -> CIImage {
        let W = src.width, H = src.height, inner = content.width / W
        let z = at(camZ, t)
        let T = screenTransform(t)
        let toOut = { (x: Double, y: Double) in CGPoint(x: x * W, y: (1 - y) * H).applying(T) }
        let pxPerPoint = ev.pointScale * z * inner // pontos da tela -> px do vídeo

        let screen = cropPx.map { screen.cropped(to: $0).transformed(by: CGAffineTransform(translationX: -$0.minX, y: -$0.minY)) } ?? screen
        var img = screen.transformed(by: T)
        let unit = min(out.width, out.height)

        // desfoque de movimento da tela (deslocamento da câmera) e do zoom, conforme a velocidade
        if st.motionBlur {
            let h = 1.0 / 60, ext = img.extent
            let pan = hypot((at(camX, t + h) - at(camX, max(0, t - h))) / (2 * h) * W, (at(camY, t + h) - at(camY, max(0, t - h))) / (2 * h) * H) * z * inner
            let r = min(12, st.screenMoveBlur * pan / 30 * 0.12)
            if r > 0.5 {
                let b = CIFilter.motionBlur()
                b.inputImage = img.clampedToExtent(); b.radius = Float(r)
                b.angle = Float(atan2(-(at(camY, t + h) - at(camY, max(0, t - h))) * H, (at(camX, t + h) - at(camX, max(0, t - h))) * W))
                img = b.outputImage!.cropped(to: ext)
            }
            let dz = abs(at(camZ, t + h) - at(camZ, max(0, t - h))) / (2 * h)
            let amount = min(8, st.screenZoomBlur * dz * 2.5)
            if amount > 0.5 {
                let b = CIFilter.zoomBlur()
                b.inputImage = img.clampedToExtent(); b.amount = Float(amount); b.center = CGPoint(x: content.midX, y: content.midY)
                img = b.outputImage!.cropped(to: ext)
            }
        }

        // mosaicos e anotações ficam presos à tela gravada (acompanham o zoom)
        for ov in st.overlays where !ov.kind.isLayout && t >= ov.a && t <= ov.b {
            let fade = min(1, (t - ov.a) / 0.2, (ov.b - t) / 0.2)
            let p0 = toOut(ov.p[0], ov.p[1]), p1 = toOut(ov.p[2], ov.p[3])
            if ov.kind == .mosaic {
                let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                guard r.width > 2, r.height > 2 else { continue }
                let px = CIFilter.pixellate()
                px.inputImage = img.clampedToExtent(); px.center = r.origin; px.scale = Float(max(2, ov.width * pxPerPoint))
                let g = CIFilter.roundedRectangleGenerator()
                g.extent = r; g.radius = Float(ov.radius * min(r.width, r.height) / 2); g.color = CIColor(red: 1, green: 1, blue: 1, alpha: fade)
                img = masked(px.outputImage!.cropped(to: r), g.outputImage!).composited(over: img)
            } else if let (cg, o) = overlayImage(ov, p0, p1, lineWidth: ov.width * unit / 720 * z, alpha: ov.opacity * fade) {
                img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: o.x, y: o.y)).composited(over: img)
            }
        }

        // efeitos de clique, ancorados onde o clique aconteceu
        if st.click != .none {
            for ct in ev.clicks where t >= ct && t < ct + st.click.duration {
                let q = (t - ct) / st.click.duration
                let pt = toOut(at(curX, ct), at(curY, ct))
                let r = 22 * pxPerPoint * min(st.cursorSize / 3, 1.6) * st.clickSize / 50
                if st.click == .spotlight {
                    let env = min(1, q / 0.15) * min(1, (1 - q) / 0.35)
                    let g = CIFilter.radialGradient()
                    g.center = pt; g.radius0 = Float(r * 2.2); g.radius1 = Float(r * 2.8)
                    g.color0 = .clear; g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * env)
                    img = g.outputImage!.cropped(to: content).composited(over: img)
                } else if let cg = clickImage(st, q: q, r: r) {
                    let e = CIImage(cgImage: cg)
                    img = e.transformed(by: CGAffineTransform(translationX: pt.x - e.extent.width / 2, y: pt.y - e.extent.height / 2)).composited(over: img)
                }
            }
        }

        // cursor
        if st.showCursor {
            let pt = toOut(at(curX, t), at(curY, t))
            let alpha = st.hideIdle ? max(0, min(1, 1 - (at(idle, t) - st.idleDuration) / 0.3)) : 1
            let vxs = at(velX, t), vys = at(velY, t) // telas por segundo
            let tilt = st.cursorDirection * tanh(vxs * 4) // direção dinâmica: inclina para o lado do movimento
            let ci = cursorIndex(t)
            let rec = ci.flatMap { $0 < shapes.count ? shapes[$0] : nil }
            let isArrow = ci.flatMap { $0 < (ev.cursors?.count ?? 0) ? ev.cursors![$0].isArrow : nil } ?? true
            let art = (st.cursorStyle == 0 || !isArrow) ? (rec ?? style) : style
            if alpha > 0 {
                let f = pxPerPoint / art.pxPerPoint * st.cursorSize / 2
                let ch = Double(art.image.height)
                var cur = CIImage(cgImage: art.image)
                    .transformed(by: CGAffineTransform(translationX: -art.hot.x, y: -(ch - art.hot.y)))
                    .transformed(by: CGAffineTransform(rotationAngle: -(st.cursorAngle + tilt) * .pi / 180))
                    .transformed(by: CGAffineTransform(scaleX: f, y: f))
                    .transformed(by: CGAffineTransform(translationX: pt.x, y: pt.y))
                // desfoque de movimento: rastro na direção do deslocamento de um quadro (30 fps)
                let px = (vxs * W * z * inner, -vys * H * z * inner), speed = hypot(px.0, px.1)
                let radius = st.motionBlur ? min(40, st.cursorBlur * speed / 30 * 0.5) : 0
                if radius > 0.5 {
                    let b = CIFilter.motionBlur()
                    b.inputImage = cur; b.radius = Float(radius); b.angle = Float(atan2(px.1, px.0))
                    cur = b.outputImage!
                }
                if alpha < 1 {
                    let m = CIFilter.colorMatrix(); m.inputImage = cur; m.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
                    cur = m.outputImage!
                }
                img = cur.composited(over: img)
            }
        }

        var result: CIImage
        let rx = at(rot3X, t), ry = at(rot3Y, t), rz = at(rot3Z, t)
        if abs(rx) + abs(ry) + abs(rz) > 0.05 {
            // zoom 3D: a tela inteira (com o zoom) inclinada em perspectiva sobre o fundo
            let srect = CGRect(x: 0, y: 0, width: W, height: H).applying(T)
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = srect; g.radius = Float(cornerRadius * z); g.color = .white
            let shape = g.outputImage!
            let quad = perspective(srect, rx: rx, ry: ry, rz: rz, fov: at(fov3, t))
            let layer = quad(masked(img.cropped(to: srect), shape))
            var under = bgOnly
            if st.shadow > 0 {
                let sh = quad(masked(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: st.shadow)).cropped(to: srect), shape))
                    .applyingGaussianBlur(sigma: unit * 0.025).transformed(by: CGAffineTransform(translationX: 0, y: -unit * 0.01))
                under = sh.composited(over: under)
            }
            result = layer.composited(over: under)
        } else {
            result = masked(img.cropped(to: content), mask).composited(over: base)
        }
        if st.showCamera, let camera, let cam = cameraLayer(camera, zoom: z, t: t) { result = cam.composited(over: result) }
        // teclas de atalho, fora do zoom, embaixo (ou em cima) no centro
        if st.showKeys, let k = keyRuns.last(where: { t >= $0.a && t < $0.b }),
           let pill = keyPill(k.text, size: st.keysSize * unit * 0.042, color: st.keysColor, background: st.keysBackground) {
            let fade = min(1, (t - k.a) / 0.12, (k.b - t) / 0.2)
            let y = st.keysTop ? out.height - unit * 0.06 - Double(pill.height) : unit * 0.06
            var p = CIImage(cgImage: pill).transformed(by: CGAffineTransform(translationX: (out.width - Double(pill.width)) / 2, y: y))
            if fade < 1 {
                let m = CIFilter.colorMatrix(); m.inputImage = p; m.aVector = CIVector(x: 0, y: 0, z: 0, w: fade)
                p = m.outputImage!
            }
            result = p.composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: out))
    }

    /// Perspectiva do zoom 3D: gira o retângulo em torno do centro do quadro (X, depois Y, depois Z) e projeta com o campo de visão
    private func perspective(_ r: CGRect, rx: Double, ry: Double, rz: Double, fov: Double) -> (CIImage) -> CIImage {
        let c = CGPoint(x: content.midX, y: content.midY), d = out.height / 2 / tan(fov / 2 * .pi / 180)
        let ax = rx * .pi / 180, ay = ry * .pi / 180, az = rz * .pi / 180
        func p(_ x0: Double, _ y0: Double) -> CGPoint {
            var x = x0 - c.x, y = y0 - c.y, z = 0.0
            (y, z) = (y * cos(ax) - z * sin(ax), y * sin(ax) + z * cos(ax))
            (x, z) = (x * cos(ay) + z * sin(ay), -x * sin(ay) + z * cos(ay))
            (x, y) = (x * cos(az) - y * sin(az), x * sin(az) + y * cos(az))
            let k = min(4, d / max(d - z, d * 0.25))
            return CGPoint(x: c.x + x * k, y: c.y + y * k)
        }
        let tl = p(r.minX, r.maxY), tr = p(r.maxX, r.maxY), bl = p(r.minX, r.minY), br = p(r.maxX, r.minY)
        return { img in
            let f = CIFilter.perspectiveTransform()
            f.inputImage = img; f.topLeft = tl; f.topRight = tr; f.bottomLeft = bl; f.bottomRight = br
            return f.outputImage!
        }
    }

    /// Layout da câmera no tempo t: (tela cheia 0…1, escondida 0…1), com a "Animação" de 0,45 s nas bordas do trecho
    private func layout(_ t: Double) -> (full: Double, hidden: Double) {
        var full = 0.0, hidden = 0.0
        for o in st.overlays where o.kind.isLayout && t >= o.a && t <= o.b {
            var k = o.transition ?? true ? min(1, (t - o.a) / 0.45, (o.b - t) / 0.45) : 1
            k = k * k * (3 - 2 * k)
            if o.kind == .camFull { full = max(full, k) } else { hidden = max(hidden, k) }
        }
        return (full, hidden)
    }

    private func cameraLayer(_ input: CIImage, zoom: Double, t: Double) -> CIImage? {
        let (full, hidden) = layout(t)
        guard hidden < 0.999 else { return nil }
        var cam = input
        if let (sat, bri, con, sharp, neutral, target) = st.cameraFilter.params {
            let cc = CIFilter.colorControls(); cc.inputImage = cam; cc.saturation = Float(sat); cc.brightness = Float(bri); cc.contrast = Float(con)
            let sh = CIFilter.sharpenLuminance(); sh.inputImage = cc.outputImage; sh.sharpness = Float(sharp); sh.radius = 1.69
            let tt = CIFilter.temperatureAndTint(); tt.inputImage = sh.outputImage
            tt.neutral = CIVector(x: neutral.x, y: neutral.y); tt.targetNeutral = CIVector(x: target.x, y: target.y)
            cam = tt.outputImage!.cropped(to: input.extent)
        }
        // recorte escolhido pelo usuário (y para baixo)
        var e = cam.extent
        if let c = st.cameraCrop, c.count == 4 {
            e = CGRect(x: e.minX + c[0] * e.width, y: e.minY + (1 - c[1] - c[3]) * e.height, width: c[2] * e.width, height: c[3] * e.height)
            cam = cam.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            e = cam.extent
        }
        if st.cameraMirror { cam = cam.oriented(.upMirrored); e = cam.extent }

        let unit = min(out.width, out.height), m = 0.04 * unit
        let shrink = st.cameraShrinkOnZoom ? 1 - 0.2 * min(1, (zoom - 1) / (maxScale - 1)) : 1 // FocuSee: 0,8 no zoom
        let d = st.cameraSize * 0.7 * unit * shrink
        let right = st.cameraCorner == 0 || st.cameraCorner == 2, bottom = st.cameraCorner < 2
        let small = CGRect(x: right ? out.width - m - d : m, y: bottom ? m : out.height - m - d, width: d, height: d)
        let big = CGRect(origin: .zero, size: out)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * full }
        var rect = CGRect(x: mix(small.minX, big.minX), y: mix(small.minY, big.minY), width: mix(small.width, big.width), height: mix(small.height, big.height))
        var radius = mix(d * st.cameraRound, 0)
        if hidden > 0 { // "Sem câmera": encolhe e some
            let k = 1 - 0.3 * hidden
            rect = CGRect(x: rect.midX - rect.width * k / 2, y: rect.midY - rect.height * k / 2, width: rect.width * k, height: rect.height * k)
            radius *= k
        }
        // preenche o retângulo mantendo a proporção da câmera
        let ar = rect.width / rect.height
        let sw = min(e.width, e.height * ar), sh = sw / ar
        let f = rect.width / sw
        cam = cam.transformed(by: CGAffineTransform(translationX: -(e.midX - sw / 2), y: -(e.midY - sh / 2))
            .concatenating(CGAffineTransform(scaleX: f, y: f))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            .cropped(to: rect)
        let g = CIFilter.roundedRectangleGenerator()
        g.extent = rect; g.radius = Float(radius); g.color = .white
        var layer = masked(cam, g.outputImage!)
        // moldura (cor ou degradê) por trás da câmera
        if let cols = st.cameraBorder, !cols.isEmpty, full < 1 {
            let bw = d * 0.045 * (1 - full)
            let outer = rect.insetBy(dx: -bw, dy: -bw)
            let og = CIFilter.roundedRectangleGenerator()
            og.extent = outer; og.radius = Float(radius + bw); og.color = .white
            var fill = CIImage(color: cols[0].ci)
            if cols.count > 1 {
                let lg = CIFilter.linearGradient()
                lg.point0 = CGPoint(x: outer.minX, y: outer.maxY); lg.point1 = CGPoint(x: outer.maxX, y: outer.minY)
                lg.color0 = cols[0].ci; lg.color1 = cols[1].ci
                fill = lg.outputImage!
            }
            layer = layer.composited(over: masked(fill.cropped(to: outer), og.outputImage!))
        }
        if full < 1 {
            let shadow = masked(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4 * (1 - full))).cropped(to: rect), g.outputImage!)
                .applyingGaussianBlur(sigma: d * 0.04)
                .transformed(by: CGAffineTransform(translationX: 0, y: -d * 0.02))
            layer = layer.composited(over: shadow)
        }
        if hidden > 0 {
            let cm = CIFilter.colorMatrix(); cm.inputImage = layer; cm.aVector = CIVector(x: 0, y: 0, z: 0, w: 1 - hidden)
            layer = cm.outputImage!
        }
        return layer
    }
}

// MARK: - Composição de vídeo (preview e exportação)

/// Espaço de cor do vídeo final (Rec.709, o que o exportador grava no arquivo). O compositor converte para ele;
/// se o desenho e a marcação divergirem, o player aplica a curva errada e o vídeo sai lavado.
enum VideoColor {
    static let primaries = AVVideoColorPrimaries_ITU_R_709_2
    static let transfer = AVVideoTransferFunction_ITU_R_709_2
    static let matrix = AVVideoYCbCrMatrix_ITU_R_709_2
    static let attachments = [kCVImageBufferColorPrimariesKey: primaries, kCVImageBufferTransferFunctionKey: transfer,
                              kCVImageBufferYCbCrMatrixKey: matrix] as CFDictionary
    static let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)!.takeRetainedValue()
    /// O que a gravação da tela realmente contém (o ScreenCaptureKit marca como Rec.709, mas os valores são sRGB)
    static let screen = CGColorSpace(name: CGColorSpace.sRGB)!
}

final class FocoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let renderer: FrameRenderer
    let screenID: CMPersistentTrackID
    let cameraID: CMPersistentTrackID?
    let srcStart: Double // tempo da gravação no início do clipe
    let speed: Double
    let preview: Bool

    init(_ tl: Timeline, _ seg: Timeline.Segment, renderer: FrameRenderer, preview: Bool) {
        self.preview = preview
        timeRange = seg.range
        self.renderer = renderer
        screenID = tl.screenID; cameraID = tl.cameraID; srcStart = seg.a; speed = seg.speed
        requiredSourceTrackIDs = ([tl.screenID] + (tl.cameraID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class FocoCompositor: NSObject, AVVideoCompositing {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ r: AVAsynchronousVideoCompositionRequest) {
        guard let ins = r.videoCompositionInstruction as? FocoInstruction,
              let screen = r.sourceFrame(byTrackID: ins.screenID),
              let out = r.renderContext.newPixelBuffer() else {
            r.finish(with: FocoError("Quadro indisponível")); return
        }
        let cam = ins.cameraID.flatMap { r.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        // a gravação contém valores sRGB, apesar de marcada como Rec.709 pelo ScreenCaptureKit
        let screenImg = CIImage(cvPixelBuffer: screen, options: [.colorSpace: VideoColor.screen])
        let img = ins.renderer.frame((r.compositionTime - ins.timeRange.start).seconds * ins.speed + ins.srcStart, screen: screenImg, camera: cam)
        // a marcação continua Rec.709 (outra marcação faz o AVFoundation converter os quadros no caminho);
        // na prévia os valores são sRGB, lidos assim pelo FrameView do editor
        CVBufferSetAttachments(out, VideoColor.attachments, .shouldPropagate)
        ci.render(img, to: out, bounds: CGRect(origin: .zero, size: ins.renderer.out), colorSpace: ins.preview ? VideoColor.screen : VideoColor.space)
        r.finish(withComposedVideoFrame: out)
    }
}

struct Timeline: @unchecked Sendable {
    struct Segment { let range: CMTimeRange; let a: Double; let speed: Double } // clipe na composição
    let asset: AVMutableComposition
    let screenID: CMPersistentTrackID
    let cameraID: CMPersistentTrackID?
    let srcSize: CGSize
    let srcDuration: Double // duração da gravação
    let clips: [Clip]
    let segments: [Segment]
    let mic: [CMPersistentTrackID]
    let system: [CMPersistentTrackID]
    let clicks: [CMPersistentTrackID] // som de clique
    let key: [[Double]]
    var duration: Double { asset.duration.seconds }

    /// Volumes de cada clipe e do som de clique (mudam sem remontar a composição)
    func audioMix(_ st: Settings) -> AVAudioMix {
        let m = AVMutableAudioMix()
        m.inputParameters = (mic.map { ($0, \Clip.mic) } + system.map { ($0, \Clip.system) }).map { id, vol in
            let p = AVMutableAudioMixInputParameters(); p.trackID = id
            for (seg, c) in zip(segments, st.clips.isEmpty ? clips : st.clips) { p.setVolume(Float(c[keyPath: vol]), at: seg.range.start) }
            return p
        } + clicks.map { id in
            let p = AVMutableAudioMixInputParameters(); p.trackID = id; p.setVolume(Float(st.clickVolume), at: .zero); return p
        }
        return m
    }
}

/// O que obriga a remontar a composição (o resto muda só o desenho ou os volumes)
func timelineKey(_ st: Settings) -> [[Double]] {
    st.clips.map { [$0.a, $0.b, $0.speed] } + [[st.clickSound ? 1 : 0, Double(st.clickSoundID)]]
}

private func sec(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

func makeTimeline(_ p: Project, events: Events, settings st: Settings) async throws -> Timeline {
    let raw = AVURLAsset(url: p.raw)
    guard let v = try await raw.loadTracks(withMediaType: .video).first else { throw FocoError("Gravação sem vídeo") }
    let rawDur = try await raw.load(.duration).seconds
    let clips = st.timelineClips(duration: rawDur).compactMap { c -> Clip? in
        var c = c; c.a = max(0, c.a); c.b = min(c.b, rawDur); return c.b - c.a > 0.05 ? c : nil
    }
    guard !clips.isEmpty else { throw FocoError("O vídeo ficou vazio") }

    let comp = AVMutableComposition()
    let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var mic: [CMPersistentTrackID] = [], system: [CMPersistentTrackID] = []
    var audio: [(AVAssetTrack, AVMutableCompositionTrack)] = []
    let rawAudio = try await raw.loadTracks(withMediaType: .audio)
    for (i, a) in rawAudio.enumerated() {
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        audio.append((a, at))
        let role = events.audio?.count == rawAudio.count ? events.audio![i] : "system" // gravações antigas: só havia áudio do sistema
        if role == "mic" { mic.append(at.trackID) } else { system.append(at.trackID) }
    }
    let camAsset = p.camera.map { AVURLAsset(url: $0) } // precisa viver até o insertTimeRange
    let cv = try await camAsset?.loadTracks(withMediaType: .video).first
    let camDur = try await cv?.load(.timeRange).duration.seconds ?? 0
    let off = events.cameraOffset ?? 0
    let ct = cv == nil ? nil : comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)

    var at = CMTime.zero, segments: [Timeline.Segment] = []
    for c in clips {
        let range = CMTimeRange(start: sec(c.a), end: sec(c.b))
        try vt.insertTimeRange(range, of: v, at: at)
        for (a, t) in audio { try t.insertTimeRange(range, of: a, at: at) }
        if let cv, let ct {
            let cs = max(0, c.a - off), ce = min(camDur, c.b - off)
            if ce > cs { try ct.insertTimeRange(CMTimeRange(start: sec(cs), end: sec(ce)), of: cv, at: at + sec(cs + off - c.a)) }
        }
        let out = abs(c.speed - 1) > 0.001 ? sec(c.len) : range.duration
        if abs(c.speed - 1) > 0.001 { comp.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: out) }
        segments.append(.init(range: CMTimeRange(start: at, duration: out), a: c.a, speed: c.speed))
        at = at + out
    }
    // som de clique: uma faixa por sobreposição, cada clique no seu tempo do vídeo final
    var clickIDs: [CMPersistentTrackID] = []
    let soundName = Settings.clickSounds[min(max(st.clickSoundID, 0), Settings.clickSounds.count - 1)].1
    let sound = AVURLAsset(url: URL(fileURLWithPath: "/System/Library/Sounds/\(soundName).aiff"))
    if st.clickSound, let snd = try await sound.loadTracks(withMediaType: .audio).first {
        let sdur = try await snd.load(.timeRange).duration
        var lanes: [(AVMutableCompositionTrack, CMTime)] = []
        for ct in events.clicks.sorted() {
            guard let k = clips.firstIndex(where: { ct >= $0.a && ct < $0.b }) else { continue }
            let t = segments[k].range.start + sec((ct - clips[k].a) / clips[k].speed)
            let len = CMTimeMinimum(sdur, at - t)
            guard len.seconds > 0.01 else { continue }
            let li = lanes.firstIndex { $0.1 <= t } ?? {
                lanes.append((comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!, .zero))
                return lanes.count - 1
            }()
            let (track, end) = lanes[li]
            if t > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: t)) }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: snd, at: t)
            lanes[li].1 = t + len
        }
        clickIDs = lanes.map { $0.0.trackID }
    }
    var used = st; used.clips = clips
    let size = try await v.load(.naturalSize)
    return Timeline(asset: comp, screenID: vt.trackID, cameraID: ct?.trackID, srcSize: size, srcDuration: rawDur,
                    clips: clips, segments: segments, mic: mic, system: system, clicks: clickIDs, key: timelineKey(used))
}

func videoComposition(_ tl: Timeline, renderer: FrameRenderer, fps: Int32, preview: Bool = false) -> AVMutableVideoComposition {
    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = FocoCompositor.self
    vc.renderSize = renderer.out
    vc.frameDuration = CMTime(value: 1, timescale: fps)
    vc.colorPrimaries = VideoColor.primaries
    vc.colorTransferFunction = VideoColor.transfer
    vc.colorYCbCrMatrix = VideoColor.matrix
    vc.instructions = tl.segments.map { FocoInstruction(tl, $0, renderer: renderer, preview: preview) }
    return vc
}

// MARK: - Exportação (MP4 ou GIF)

struct RenderInputs: @unchecked Sendable {
    let project: Project
    let events: Events
    let settings: Settings
    let style: CursorArt
    let shapes: [CursorArt?]
}

/// Tamanho final para uma resolução (nil = original)
func outputSize(_ inp: RenderInputs, src: CGSize, shortSide: Double?) -> CGSize {
    let side = shortSide ?? min(src.width, src.height)
    return FrameRenderer(settings: inp.settings, events: Events(samples: [], clicks: [], pointScale: 2), style: inp.style, shapes: [],
                         src: src, shortSide: side, duration: 0).out
}

func exportVideo(_ inp: RenderInputs, options o: ExportOptions, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let st = inp.settings
    let tl = try await makeTimeline(inp.project, events: inp.events, settings: st)
    let side = o.shortSide ?? min(tl.srcSize.width, tl.srcSize.height)
    let r = FrameRenderer(settings: st, events: inp.events, style: inp.style, shapes: inp.shapes, src: tl.srcSize, shortSide: side,
                          duration: tl.srcDuration)
    let folder = URL(fileURLWithPath: o.folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let ext = o.format == .gif ? "gif" : "mp4"
    var url = folder.appending(path: "\(name).\(ext)")
    var n = 1
    while FileManager.default.fileExists(atPath: url.path) { url = folder.appending(path: "\(name)_\(n).\(ext)"); n += 1 }

    let reader = try AVAssetReader(asset: tl.asset)
    let videoTracks = try await tl.asset.loadTracks(withMediaType: .video)
    let vout = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    vout.videoComposition = videoComposition(tl, renderer: r, fps: Int32(o.fps))
    reader.add(vout)
    let total = tl.duration

    if o.format == .gif {
        guard reader.startReading() else { throw reader.error ?? FocoError("Falha ao ler o vídeo") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, Int(total * Double(o.fps)) + 1, nil)
        else { throw FocoError("Não foi possível criar o GIF") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let ci = CIContext()
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(o.fps)]] as CFDictionary
        while let sb = vout.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: VideoColor.space])
            if let cg = ci.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                CGImageDestinationAddImage(dest, cg, frameProps)
            }
            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total))
        }
        if reader.status == .failed { throw reader.error ?? FocoError("Falha ao ler o vídeo") }
        guard CGImageDestinationFinalize(dest) else { throw FocoError("Falha ao salvar o GIF") }
        return url
    }

    let audioTracks = try await tl.asset.loadTracks(withMediaType: .audio)
    var aout: AVAssetReaderAudioMixOutput?
    if !audioTracks.isEmpty {
        let a = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        a.audioMix = tl.audioMix(st)
        a.audioTimePitchAlgorithm = .spectral // velocidade sem mudar o tom da voz
        reader.add(a); aout = a
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let bitrate = r.out.width * r.out.height * Double(o.fps) * o.quality.bitsPerPixel
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: r.out.width, AVVideoHeightKey: r.out.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: o.fps,
                                          AVVideoMaxKeyFrameIntervalKey: o.fps * 2, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: VideoColor.primaries, AVVideoTransferFunctionKey: VideoColor.transfer,
                                    AVVideoYCbCrMatrixKey: VideoColor.matrix],
    ])
    vin.expectsMediaDataInRealTime = false
    writer.add(vin)
    var ain: AVAssetWriterInput?
    if aout != nil {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2,
                                                                       AVSampleRateKey: 48000, AVEncoderBitRateKey: 160_000])
        a.expectsMediaDataInRealTime = false
        writer.add(a); ain = a
    }

    guard reader.startReading() else { throw reader.error ?? FocoError("Falha ao ler o vídeo") }
    guard writer.startWriting() else { throw writer.error ?? FocoError("Falha ao gravar o arquivo") }
    writer.startSession(atSourceTime: .zero)

    final class Box: @unchecked Sendable { var done = false }
    func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, report: Bool) async {
        let box = Box()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData && !box.done {
                    if let sb = output.copyNextSampleBuffer() {
                        input.append(sb)
                        if report { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total)) }
                    } else {
                        box.done = true
                        input.markAsFinished()
                        c.resume()
                    }
                }
            }
        }
    }
    await withTaskGroup(of: Void.self) { g in
        g.addTask { await pump(vin, vout, label: "foco.export.video", report: true) }
        if let ain, let aout { g.addTask { await pump(ain, aout, label: "foco.export.audio", report: false) } }
    }
    if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? FocoError("Falha ao ler o vídeo") }
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? FocoError("Falha ao gravar o arquivo") }
    return url
}
