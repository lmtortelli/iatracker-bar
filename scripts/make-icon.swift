// Gera o logo do IAtracker-bar: ícone do app (.icns), PNG para o README e SVG vetorial.
// Uso: swift scripts/make-icon.swift
//
// Conceito: ᚨ Ansuz (Futhark Antigo) — a runa de Odin, da sabedoria e da comunicação —
// cuja haste é ᛁ Isa: juntas, "I" e "A". Gravada em cobre numa placa de pedra escura,
// cercada por um anel de medidor (o limite de uso) e, nos tamanhos grandes, pela palavra
// IATRACKER em runas: ᛁᚨᛏᚱᚨᚲᚲᛖᚱ.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometria (tela de 1024, y para baixo)

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
let center = CGPoint(x: 512, y: 512)
let ringRadius: CGFloat = 292
let ringWidth: CGFloat = 34
let ringProgress: CGFloat = 0.63
let bandRadius: CGFloat = 362
let bandGlyphHeight: CGFloat = 40

/// Ansuz: haste + dois ramos descendo para a direita.
let ansuz: [[CGPoint]] = [
    [CGPoint(x: 452, y: 334), CGPoint(x: 452, y: 690)],
    [CGPoint(x: 452, y: 334), CGPoint(x: 584, y: 424)],
    [CGPoint(x: 452, y: 442), CGPoint(x: 584, y: 532)],
]

/// Runas em coordenadas unitárias (largura 0,6 × altura 1, centro em 0,3 × 0,5).
let runes: [Character: [[CGPoint]]] = [
    "ᛁ": [[CGPoint(x: 0.3, y: 0), CGPoint(x: 0.3, y: 1)]],
    "ᚨ": [[CGPoint(x: 0.12, y: 0), CGPoint(x: 0.12, y: 1)],
          [CGPoint(x: 0.12, y: 0), CGPoint(x: 0.55, y: 0.3)],
          [CGPoint(x: 0.12, y: 0.32), CGPoint(x: 0.55, y: 0.62)]],
    "ᛏ": [[CGPoint(x: 0.3, y: 0), CGPoint(x: 0.3, y: 1)],
          [CGPoint(x: 0.02, y: 0.3), CGPoint(x: 0.3, y: 0), CGPoint(x: 0.58, y: 0.3)]],
    "ᚱ": [[CGPoint(x: 0.1, y: 0), CGPoint(x: 0.1, y: 1)],
          [CGPoint(x: 0.1, y: 0), CGPoint(x: 0.52, y: 0.25), CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.52, y: 1)]],
    "ᚲ": [[CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.8)]],
    "ᛖ": [[CGPoint(x: 0.04, y: 1), CGPoint(x: 0.04, y: 0), CGPoint(x: 0.3, y: 0.35), CGPoint(x: 0.56, y: 0), CGPoint(x: 0.56, y: 1)]],
    "᛫": [[CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.3, y: 0.52)]],
]
let bandText = Array("ᛁᚨᛏᚱᚨᚲᚲᛖᚱ᛫ᛁᚨᛏᚱᚨᚲᚲᛖᚱ᛫")

struct RGBA { let r, g, b, a: CGFloat }
func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> RGBA {
    RGBA(r: CGFloat((value >> 16) & 0xFF) / 255, g: CGFloat((value >> 8) & 0xFF) / 255, b: CGFloat(value & 0xFF) / 255, a: alpha)
}
let stoneTop = hex(0x2C3039), stoneBottom = hex(0x14161B)
let copperTop = hex(0xF0B08A), copperBottom = hex(0xC9714A)
let glow = hex(0xCC7A50, 0.55)
let gauge = hex(0x4FB06E)
let track = hex(0xFFFFFF, 0.07)
let engraving = hex(0xFFFFFF, 0.16)

/// Posições dos glifos da faixa rúnica: (centro, ângulo em graus a partir do topo, horário).
func bandPlacements() -> [(Character, CGPoint, CGFloat)] {
    bandText.enumerated().map { index, glyph in
        let degrees = CGFloat(index) / CGFloat(bandText.count) * 360
        let radians = degrees * .pi / 180
        let point = CGPoint(x: center.x + bandRadius * sin(radians), y: center.y - bandRadius * cos(radians))
        return (glyph, point, degrees)
    }
}

// MARK: - Raster (CoreGraphics)

func cg(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("contexto") }
    let scale = CGFloat(pixels) / canvas
    // Traço mais grosso e sem detalhes finos nos tamanhos pequenos.
    let small = pixels <= 64
    let boost: CGFloat = small ? 1.5 : 1
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Placa com sombra.
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: cg(hex(0x000000, 0.35)))
    ctx.addPath(tilePath)
    ctx.setFillColor(cg(stoneBottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let stone = CGGradient(colorsSpace: space, colors: [cg(stoneTop), cg(stoneBottom)] as CFArray, locations: [0, 1])
    if let stone { ctx.drawLinearGradient(stone, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: []) }
    // Brilho sutil no topo da pedra.
    let sheen = CGGradient(colorsSpace: space, colors: [cg(hex(0xFFFFFF, 0.10)), cg(hex(0xFFFFFF, 0))] as CFArray, locations: [0, 1])
    if let sheen { ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 160), startRadius: 0, endCenter: CGPoint(x: 512, y: 160), endRadius: 520, options: []) }
    ctx.restoreGState()

    // Borda interna clara.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: tileRadius - 1.5, cornerHeight: tileRadius - 1.5, transform: nil))
    ctx.setStrokeColor(cg(hex(0xFFFFFF, 0.08)))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Faixa rúnica gravada.
    if !small {
        ctx.setStrokeColor(cg(engraving))
        ctx.setLineWidth(5)
        for (glyph, point, degrees) in bandPlacements() {
            guard let strokes = runes[glyph] else { continue }
            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            ctx.rotate(by: degrees * .pi / 180)
            for stroke in strokes {
                let mapped = stroke.map { CGPoint(x: ($0.x - 0.3) * bandGlyphHeight, y: ($0.y - 0.5) * bandGlyphHeight) }
                ctx.addLines(between: mapped)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // Anel: trilho + progresso (começa no topo, sentido horário).
    ctx.setLineWidth(ringWidth * boost)
    ctx.setStrokeColor(cg(track))
    ctx.addEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
    ctx.strokePath()
    ctx.setStrokeColor(cg(gauge))
    ctx.addArc(center: center, radius: ringRadius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * ringProgress, clockwise: false)
    ctx.strokePath()

    // Ansuz em cobre, com brilho.
    let runePath = CGMutablePath()
    for stroke in ansuz { runePath.addLines(between: stroke) }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: small ? 10 : 36, color: cg(glow))
    ctx.addPath(runePath)
    ctx.setLineWidth(46 * boost)
    ctx.setStrokeColor(cg(copperBottom))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(runePath)
    ctx.setLineWidth(46 * boost)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let copper = CGGradient(colorsSpace: space, colors: [cg(copperTop), cg(copperBottom)] as CFArray, locations: [0, 1])
    if let copper { ctx.drawLinearGradient(copper, start: CGPoint(x: 512, y: 320), end: CGPoint(x: 512, y: 700), options: []) }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("imagem") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

// MARK: - Vetor (SVG)

func svgColor(_ c: RGBA) -> String {
    String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
}

func svg() -> String {
    func points(_ stroke: [CGPoint]) -> String { stroke.map { "\($0.x),\($0.y)" }.joined(separator: " ") }
    let progressEnd = -CGFloat.pi / 2 + 2 * .pi * ringProgress
    let end = CGPoint(x: center.x + ringRadius * cos(progressEnd), y: center.y + ringRadius * sin(progressEnd))
    let band = bandPlacements().compactMap { glyph, point, degrees -> String? in
        guard let strokes = runes[glyph] else { return nil }
        let lines = strokes.map { stroke in
            "<polyline points=\"\(points(stroke.map { CGPoint(x: (($0.x - 0.3) * bandGlyphHeight).rounded(toPlaces: 2), y: (($0.y - 0.5) * bandGlyphHeight).rounded(toPlaces: 2)) }))\"/>"
        }.joined()
        return "<g transform=\"translate(\(point.x.rounded(toPlaces: 2)) \(point.y.rounded(toPlaces: 2))) rotate(\(degrees.rounded(toPlaces: 2)))\">\(lines)</g>"
    }.joined(separator: "\n      ")
    let rune = ansuz.map { "<polyline points=\"\(points($0))\"/>" }.joined()

    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <title>IAtracker-bar — ᚨ Ansuz</title>
      <defs>
        <linearGradient id="stone" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(svgColor(stoneTop))"/><stop offset="1" stop-color="\(svgColor(stoneBottom))"/>
        </linearGradient>
        <radialGradient id="sheen" cx="512" cy="160" r="520" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="copper" x1="512" y1="320" x2="512" y2="700" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(svgColor(copperTop))"/><stop offset="1" stop-color="\(svgColor(copperBottom))"/>
        </linearGradient>
        <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000000" flood-opacity="0.35"/>
        </filter>
        <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="18" result="blur"/>
          <feFlood flood-color="\(svgColor(glow))" flood-opacity="\(glow.a)"/>
          <feComposite in2="blur" operator="in"/>
          <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
        </filter>
      </defs>
      <rect x="\(tile.minX)" y="\(tile.minY)" width="\(tile.width)" height="\(tile.height)" rx="\(tileRadius)" fill="url(#stone)" filter="url(#shadow)"/>
      <rect x="\(tile.minX)" y="\(tile.minY)" width="\(tile.width)" height="\(tile.height)" rx="\(tileRadius)" fill="url(#sheen)"/>
      <rect x="\(tile.minX + 1.5)" y="\(tile.minY + 1.5)" width="\(tile.width - 3)" height="\(tile.height - 3)" rx="\(tileRadius - 1.5)" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="3"/>
      <g fill="none" stroke="#FFFFFF" stroke-opacity="\(engraving.a)" stroke-width="5" stroke-linecap="round" stroke-linejoin="round">
          \(band)
      </g>
      <circle cx="\(center.x)" cy="\(center.y)" r="\(ringRadius)" fill="none" stroke="#FFFFFF" stroke-opacity="\(track.a)" stroke-width="\(ringWidth)"/>
      <path d="M \(center.x) \(center.y - ringRadius) A \(ringRadius) \(ringRadius) 0 1 1 \(end.x.rounded(toPlaces: 2)) \(end.y.rounded(toPlaces: 2))" fill="none" stroke="\(svgColor(gauge))" stroke-width="\(ringWidth)" stroke-linecap="round"/>
      <g fill="none" stroke="url(#copper)" stroke-width="46" stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)">\(rune)</g>
    </svg>

    """
}

extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}

// MARK: - Saída

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

writePNG(render(pixels: 512), to: root.appendingPathComponent("docs/images/logo.png"))
writePNG(render(pixels: 64), to: root.appendingPathComponent("docs/images/logo-64.png"))
try svg().write(to: root.appendingPathComponent("docs/logo.svg"), atomically: true, encoding: .utf8)

print("✓ \(icns.path)")
print("✓ docs/images/logo.png, docs/images/logo-64.png, docs/logo.svg")
