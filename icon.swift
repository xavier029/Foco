// Gera icon.png (1024x1024) a partir de logo.jpg, no gabarito de ícones do macOS:
// arte de 824x824 centralizada, cantos arredondados (raio 185) e margem transparente.
// Uso: swift icon.swift
import AppKit

let src = NSImage(contentsOfFile: "logo.jpg")!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185).addClip()
NSGraphicsContext.current!.imageInterpolation = .high
src.draw(in: r)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))
print("ok: icon.png")
