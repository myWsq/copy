import AppKit
// argv: glyph.png outDir  —— 生成菜单栏模板图：裁到字形外框，等比缩放进 18pt 画布，纯黑 + alpha
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("load") }
let w = cg.width, h = cg.height
var buf = [UInt8](repeating: 0, count: w*h*4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var minX = w, maxX = -1, minY = h, maxY = -1
for y in 0..<h { for x in 0..<w where buf[(y*w + x)*4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let bw = maxX - minX + 1, bh = maxY - minY + 1
print("字形外框 \(bw)x\(bh) @ (\(minX),\(minY))")
let cropped = ctx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh))!

// 18pt 画布，字形占 15pt —— 与 SF Symbols 在同尺寸下的实际绘制高度对齐，太满会比邻居显重
for scale in [1, 2, 3] {
    let canvas = 18*scale, target = CGFloat(15*scale)
    let k = min(target/CGFloat(bw), target/CGFloat(bh))
    let dw = CGFloat(bw)*k, dh = CGFloat(bh)*k
    let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    out.draw(cropped, in: CGRect(x: (CGFloat(canvas)-dw)/2, y: (CGFloat(canvas)-dh)/2, width: dw, height: dh))
    // 模板图只看 alpha，把颜色统一压成黑
    var b = [UInt8](repeating: 0, count: canvas*canvas*4)
    let f = CGContext(data: &b, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas*4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    f.draw(out.makeImage()!, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    for i in 0..<(canvas*canvas) { b[i*4] = 0; b[i*4+1] = 0; b[i*4+2] = 0 }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let path = "\(a[2])/menubar\(suffix).png"
    try! NSBitmapImageRep(cgImage: f.makeImage()!)
        .representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(canvas)x\(canvas)")
}
