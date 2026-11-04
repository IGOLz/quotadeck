// Cuts the Codex cloud out of the official icon that ships in ChatGPT.app
// (white squircle background) and writes it as a transparent, square PNG.
//   swift scripts/assets/extract-codex-logo.swift <icon-codex-light.png> <out.png> [size]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: extract-codex-logo <icon-codex-light.png> <out.png> [size]")
}
let outSize = args.count > 3 ? Int(args[3])! : 256
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

/// How far a pixel is from the neutral white/grey background (0 = background).
func chroma(_ i: Int) -> Double {
    let a = Double(px[i + 3]) / 255
    guard a > 0.01 else { return 0 }
    let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
    return max(r, g, b) - min(r, g, b)
}

// Flood-fill the background from the borders through low-chroma pixels. The ">_"
// glyph is light too, but it is enclosed by the cloud, so it stays opaque.
let threshold = 0.16
var isBG = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let p = stack.popLast() {
    if isBG[p] || chroma(p * 4) >= threshold { continue }
    isBG[p] = true
    let x = p % w, y = p / w
    if x > 0 { stack.append(p - 1) }
    if x < w - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - w) }
    if y < h - 1 { stack.append(p + w) }
}

// Background pixels become transparent, edge pixels partially so (un-blended from white).
var out = [UInt8](repeating: 0, count: w * h * 4)
var minX = w, minY = h, maxX = 0, maxY = 0
for p in 0..<(w * h) {
    let i = p * 4
    var alpha = 1.0
    if isBG[p] { alpha = min(1, max(0, (chroma(i) - 0.03) / (threshold - 0.03))) }
    guard alpha > 0.003 else { continue }
    let srcA = Double(px[i + 3]) / 255
    for c in 0..<3 {
        let v = srcA > 0 ? Double(px[i + c]) / 255 / srcA : 0
        let un = alpha < 1 ? min(1, max(0, (v - (1 - alpha) * 0.97) / alpha)) : v
        out[i + c] = UInt8((un * alpha * 255).rounded())  // premultiplied
    }
    out[i + 3] = UInt8((alpha * 255).rounded())
    let x = p % w, y = p / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}

let full = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
// Crop to the cloud, centred in a square with a little padding.
let side = Int(Double(max(maxX - minX, maxY - minY)) * 1.04)
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let crop = full.cropping(to: CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side))!
let dst = CGContext(data: nil, width: outSize, height: outSize, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
dst.interpolationQuality = .high
dst.draw(crop, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
let rep = NSBitmapImageRep(cgImage: dst.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(outSize)px, cloud \(maxX - minX)x\(maxY - minY) of \(w)x\(h))")
