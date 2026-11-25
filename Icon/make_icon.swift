// Disegna l'icona dell'app (un registratore a cassette) e la salva come PNG 1024x1024.
// Uso: swift Icon/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func fillGradient(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: bottom, ending: top)!.draw(in: path.bounds, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
}

// Sfondo: squircle macOS (824x824 centrato, raggio ~185)
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
color(0x1E2A4A).setFill()
bg.fill()
NSGraphicsContext.restoreGraphicsState()
fillGradient(bg, color(0x3A4F86), color(0x161E38))

// Corpo del registratore
let body = NSRect(x: 190, y: 250, width: 644, height: 470)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 56, yRadius: 56)
NSGraphicsContext.saveGraphicsState()
let s2 = NSShadow()
s2.shadowColor = color(0x000000, 0.45)
s2.shadowOffset = NSSize(width: 0, height: -10)
s2.shadowBlurRadius = 20
s2.set()
color(0xD9DDE6).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()
fillGradient(bodyPath, color(0xF2F4F8), color(0xB9C0CE))

// Maniglia
let handle = NSBezierPath()
handle.lineWidth = 26
handle.lineCapStyle = .round
handle.move(to: NSPoint(x: 340, y: 720))
handle.line(to: NSPoint(x: 340, y: 790))
handle.line(to: NSPoint(x: 684, y: 790))
handle.line(to: NSPoint(x: 684, y: 720))
handle.lineJoinStyle = .round
color(0xC9CFDB).setStroke()
handle.stroke()

// Finestra della cassetta
let window = NSRect(x: 240, y: 430, width: 544, height: 240)
let windowPath = NSBezierPath(roundedRect: window, xRadius: 30, yRadius: 30)
fillGradient(windowPath, color(0x2B2F3A), color(0x14161C))

// Nastro tra le bobine
let tape = NSRect(x: 380, y: 500, width: 264, height: 30)
color(0x5A3B2A).setFill()
NSBezierPath(rect: tape).fill()

// Bobine
func reel(center c: NSPoint) {
    let r: CGFloat = 78
    let outer = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    color(0x6B4632).setFill()
    outer.fill()
    let hubR: CGFloat = 40
    let hub = NSBezierPath(ovalIn: NSRect(x: c.x - hubR, y: c.y - hubR, width: 2 * hubR, height: 2 * hubR))
    color(0xEDEFF4).setFill()
    hub.fill()
    // denti del mozzo
    color(0x2B2F3A).setFill()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3
        let p = NSPoint(x: c.x + cos(a) * 24, y: c.y + sin(a) * 24)
        NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
    }
    let dot: CGFloat = 10
    NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot)).fill()
}
reel(center: NSPoint(x: 370, y: 550))
reel(center: NSPoint(x: 654, y: 550))

// Riflesso sul vetro
NSGraphicsContext.saveGraphicsState()
windowPath.addClip()
let gloss = NSBezierPath()
gloss.move(to: NSPoint(x: 240, y: 670))
gloss.line(to: NSPoint(x: 520, y: 670))
gloss.line(to: NSPoint(x: 400, y: 430))
gloss.line(to: NSPoint(x: 240, y: 430))
gloss.close()
color(0xFFFFFF, 0.07).setFill()
gloss.fill()
NSGraphicsContext.restoreGraphicsState()

// Tasti: tre grigi + REC rosso
func key(_ x: CGFloat, _ top: NSColor, _ bottom: NSColor) {
    let r = NSRect(x: x, y: 300, width: 100, height: 90)
    let p = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
    fillGradient(p, top, bottom)
}
key(250, color(0x8E96A8), color(0x5D6578))
key(370, color(0x8E96A8), color(0x5D6578))
key(490, color(0x8E96A8), color(0x5D6578))

// Tasto REC
let recRect = NSRect(x: 620, y: 290, width: 164, height: 110)
let recPath = NSBezierPath(roundedRect: recRect, xRadius: 24, yRadius: 24)
fillGradient(recPath, color(0x4A505E), color(0x2A2E38))
let dotR: CGFloat = 36
let recDot = NSBezierPath(ovalIn: NSRect(x: recRect.midX - dotR, y: recRect.midY - dotR, width: 2 * dotR, height: 2 * dotR))
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = color(0xFF3B30, 0.8)
glow.shadowBlurRadius = 22
glow.shadowOffset = .zero
glow.set()
color(0xFF3B30).setFill()
recDot.fill()
NSGraphicsContext.restoreGraphicsState()
fillGradient(recDot, color(0xFF6A5E), color(0xD91E14))

// Simboli sui tasti grigi: play, stop, pausa
color(0xEDEFF4).setFill()
let play = NSBezierPath()
play.move(to: NSPoint(x: 285, y: 325)); play.line(to: NSPoint(x: 285, y: 365)); play.line(to: NSPoint(x: 320, y: 345)); play.close()
play.fill()
NSBezierPath(rect: NSRect(x: 401, y: 326, width: 38, height: 38)).fill()
NSBezierPath(rect: NSRect(x: 522, y: 326, width: 13, height: 38)).fill()
NSBezierPath(rect: NSRect(x: 545, y: 326, width: 13, height: 38)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icona salvata in \(out)")
