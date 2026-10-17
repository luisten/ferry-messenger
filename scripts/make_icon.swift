// Renders Ferry's app icon and launch mark from the design's SVGs with CoreGraphics (no image tools, no packages), so
// the PNGs can't drift from the files the designer hands over (DESIGN §18, "Deep water").
//
//   swift scripts/make_icon.swift                              # from the repo root
//   swift scripts/make_icon.swift <Assets.xcassets> <dir with the SVGs>
//
// Reads docs/design/ferry-icon-color.svg, -color-dark.svg and -color-tinted.svg and writes into the asset catalog:
//   AppIcon.appiconset/AppIcon.png          light: the sea gradient, opaque (no alpha channel at all: App Store rule)
//   AppIcon.appiconset/AppIcon-dark.png     dark: transparent, iOS draws its own backdrop behind it
//   AppIcon.appiconset/AppIcon-tinted.png   tinted: greys on transparent, iOS tints them by luminance
//   LaunchMark.imageset/LaunchMark@2x/@3x.png       the light icon without its background (white and foam), 120 pt
//   LaunchMark.imageset/LaunchMark-dark@2x/@3x.png  the dark icon as is, 120 pt
// The Contents.json files next to them are checked in; this only redraws the PNGs.
//
// The SVGs use only what this draws (their header comments say so): one vertical <linearGradient> in user space, one
// <rect> filled with it, then <path>s with absolute M H V C Z, each filled (nonzero) or stroked (width, round caps and
// joins), drawn in document order. Anything else stops the script rather than render something different.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments.dropFirst()
let assets = URL(fileURLWithPath: args.first ?? "Ferry/Assets.xcassets", isDirectory: true)
let design = URL(fileURLWithPath: args.dropFirst().first ?? "docs/design", isDirectory: true)
let artboard: CGFloat = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Reading the SVG

struct Element {
    let name: String
    let attributes: [String: String]
    subscript(_ key: String) -> String? { attributes[key] }
}

final class Collector: NSObject, XMLParserDelegate {
    var elements: [Element] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        elements.append(Element(name: name, attributes: attributes))
    }
}

func elements(of file: String) -> [Element] {
    let url = design.appendingPathComponent(file)
    guard let parser = XMLParser(contentsOf: url) else { fatalError("can't read \(url.path)") }
    let collector = Collector()
    parser.delegate = collector
    guard parser.parse() else { fatalError("\(url.path): \(parser.parserError.map(String.init(describing:)) ?? "not XML")") }
    return collector.elements
}

func color(_ hex: String) -> CGColor {
    guard hex.hasPrefix("#"), hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { fatalError("colour \(hex)") }
    let c = [CGFloat((rgb >> 16) & 0xFF), CGFloat((rgb >> 8) & 0xFF), CGFloat(rgb & 0xFF)].map { $0 / 255 }
    return CGColor(colorSpace: sRGB, components: c + [1])!
}

func number(_ text: String?) -> CGFloat {
    guard let text, let value = Double(text) else { fatalError("number \(text ?? "nil")") }
    return CGFloat(value)
}

/// `d` with absolute M, H, V, C and Z only (DESIGN §18's rule for these files).
func path(_ d: String) -> CGPath {
    var tokens: [String] = []
    var current = ""
    for ch in d {
        if ch.isLetter || ch == " " || ch == "," {
            if !current.isEmpty { tokens.append(current); current = "" }
            if ch.isLetter { tokens.append(String(ch)) }
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty { tokens.append(current) }

    let path = CGMutablePath()
    var i = 0
    var point = CGPoint.zero
    func next() -> CGFloat { defer { i += 1 }; return number(tokens[i]) }
    while i < tokens.count {
        let command = tokens[i]
        i += 1
        switch command {
        case "M": point = CGPoint(x: next(), y: next()); path.move(to: point)
        case "H": point.x = next(); path.addLine(to: point)
        case "V": point.y = next(); path.addLine(to: point)
        case "C":
            let c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next())
            point = CGPoint(x: next(), y: next())
            path.addCurve(to: point, control1: c1, control2: c2)
        case "Z": path.closeSubpath()
        default: fatalError("path command \(command) (only absolute M H V C Z)")
        }
    }
    return path
}

// MARK: - Drawing

/// Draws `file` at `pixels` square. `opaque`: no alpha channel (the light icon). `background`: false leaves out the
/// gradient-filled rect (the launch mark is the light icon without its tile).
func render(_ file: String, pixels: Int, opaque: Bool, background: Bool = true) -> CGImage {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: alpha.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: CGFloat(pixels) / artboard, y: -CGFloat(pixels) / artboard)  // SVG units, top-left origin
    ctx.clear(CGRect(x: 0, y: 0, width: artboard, height: artboard))

    var gradients: [String: (start: CGPoint, end: CGPoint, stops: [(CGFloat, CGColor)])] = [:]
    var open: String?
    for e in elements(of: file) {
        switch e.name {
        case "svg", "title", "defs":
            continue
        case "linearGradient":
            guard e["gradientUnits"] == "userSpaceOnUse", let id = e["id"] else { fatalError("\(file): gradient must be in user space") }
            gradients[id] = (CGPoint(x: number(e["x1"]), y: number(e["y1"])), CGPoint(x: number(e["x2"]), y: number(e["y2"])), [])
            open = id
        case "stop":
            guard let id = open, let hex = e["stop-color"] else { fatalError("\(file): stray <stop>") }
            gradients[id]!.stops.append((number(e["offset"]), color(hex)))
        case "rect":
            guard let fill = e["fill"], fill.hasPrefix("url(#"), let g = gradients[String(fill.dropFirst(5).dropLast())] else {
                fatalError("\(file): a rect must be filled with a gradient")
            }
            guard background else { continue }
            let gradient = CGGradient(colorsSpace: sRGB, colors: g.stops.map(\.1) as CFArray, locations: g.stops.map(\.0))!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: number(e["x"]), y: number(e["y"]), width: number(e["width"]), height: number(e["height"])))
            ctx.drawLinearGradient(gradient, start: g.start, end: g.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        case "path":
            ctx.addPath(path(e["d"] ?? ""))
            if let stroke = e["stroke"], stroke != "none" {
                guard e["stroke-linecap"] == "round", e["stroke-linejoin"] == "round", e["fill"] == "none" else {
                    fatalError("\(file): strokes are round-capped, round-joined and unfilled")
                }
                ctx.setStrokeColor(color(stroke))
                ctx.setLineWidth(number(e["stroke-width"]))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            } else if let fill = e["fill"] {
                ctx.setFillColor(color(fill))
                ctx.fillPath()  // nonzero
            } else {
                fatalError("\(file): a path needs a fill or a stroke")
            }
        default:
            fatalError("\(file): <\(e.name)> isn't something this script draws")
        }
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = assets.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
    print("wrote \(url.path)")
}

// The app draws the same shapes for O1's scene and the onboarding deck (Ferry/FerryShape.swift). Its copy of the path
// data is checked here, where the SVGs are read anyway (the unit tests only see bundled fixtures).
let shapes = assets.deletingLastPathComponent().appendingPathComponent("FerryShape.swift")
if let swift = try? String(contentsOf: shapes, encoding: .utf8) {
    for file in ["ferry-icon-color.svg", "ferry-icon-color-dark.svg", "ferry-icon-color-tinted.svg"] {
        for d in elements(of: file).compactMap({ $0.name == "path" ? $0["d"] : nil }) where !swift.contains("\"\(d)\"") {
            fatalError("\(shapes.path) doesn't have \(file)'s path \(d.prefix(24))…: copy it into FerryShape.Part.d")
        }
    }
    print("checked \(shapes.lastPathComponent): same paths as the SVGs")
}

write(render("ferry-icon-color.svg", pixels: 1024, opaque: true), "AppIcon.appiconset/AppIcon.png")
write(render("ferry-icon-color-dark.svg", pixels: 1024, opaque: false), "AppIcon.appiconset/AppIcon-dark.png")
write(render("ferry-icon-color-tinted.svg", pixels: 1024, opaque: false), "AppIcon.appiconset/AppIcon-tinted.png")
for scale in [2, 3] {  // 120 pt (DESIGN §18.2)
    write(render("ferry-icon-color.svg", pixels: 120 * scale, opaque: false, background: false), "LaunchMark.imageset/LaunchMark@\(scale)x.png")
    write(render("ferry-icon-color-dark.svg", pixels: 120 * scale, opaque: false), "LaunchMark.imageset/LaunchMark-dark@\(scale)x.png")
}
