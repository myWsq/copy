import AppKit
// argv: in out size —— 抽出实心 C 字形（白色 + alpha），不含背景、不含任何手绘光效。
// 分割靠饱和度（背景是饱和的绿，字形是低饱和的白），但字形下半透出背景色、饱和度升高，
// 单纯阈值会把它挖空。所以只用宽松阈值圈出轮廓，再从图像四边 flood fill 背景，
// 取补集得到实心形状 —— 只依赖轮廓连续，不依赖字形内部有多透。
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("load") }
let w = cg.width, h = cg.height, outSize = Int(a[3])!
var buf = [UInt8](repeating: 0, count: w*h*4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func sstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(max((x - e0)/(e1 - e0), 0), 1); return t*t*(3 - 2*t)
}

var sat = [Double](repeating: 0, count: w*h)
var inside = [Double](repeating: 0, count: w*h)
for i in 0..<(w*h) {
    let r = Double(buf[i*4])/255, g = Double(buf[i*4+1])/255, b = Double(buf[i*4+2])/255
    inside[i] = sstep(0.02, 0.20, 0.2126*r + 0.7152*g + 0.0722*b)
    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
    sat[i] = mx > 0 ? (mx - mn)/mx : 1     // 圆角外的黑当成"最饱和"，即背景
}

// 背景绿的饱和度最低约 0.33，字形最高约 0.32 —— 几乎不重叠，固定阈值就够分。
// 背景在图内还有水平方向的渐变，按行取基准反而会误判，别再往那个方向"改进"。
var passable = [Bool](repeating: false, count: w*h)
for i in 0..<(w*h) {
    if inside[i] < 0.1 { passable[i] = true; continue }        // 圆角外
    passable[i] = sat[i] > 0.33
}

// 从四边 flood fill 出背景（含 C 的内圆，它经开口与外部连通）
var bg = [Bool](repeating: false, count: w*h)
var q = [Int](); q.reserveCapacity(w*h)
for x in 0..<w { for y in [0, h-1] where !bg[y*w + x] && passable[y*w + x] { bg[y*w + x] = true; q.append(y*w + x) } }
for y in 0..<h { for x in [0, w-1] where !bg[y*w + x] && passable[y*w + x] { bg[y*w + x] = true; q.append(y*w + x) } }
var head = 0
while head < q.count {
    let i = q[head]; head += 1
    let x = i % w, y = i / w
    for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
        let j = ny*w + nx
        if !bg[j] && passable[j] { bg[j] = true; q.append(j) }
    }
}

// 背景最亮的角落饱和度会掉到阈值以下，flood fill 进不去，留下贴边的碎块。
// 字形是单一连通域，只保留补集里最大的那块即可 —— 比继续调阈值稳。
var keep = [Bool](repeating: false, count: w*h)
var seen = [Bool](repeating: false, count: w*h)
var best = 0
for start in 0..<(w*h) where !bg[start] && !seen[start] {
    var comp = [Int]([start]); seen[start] = true
    var k = 0
    while k < comp.count {
        let i = comp[k]; k += 1
        let x = i % w, y = i / w
        for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            let j = ny*w + nx
            if !bg[j] && !seen[j] { seen[j] = true; comp.append(j) }
        }
    }
    if comp.count > best { best = comp.count; keep = [Bool](repeating: false, count: w*h); for i in comp { keep[i] = true } }
}
for i in 0..<(w*h) where !keep[i] { bg[i] = true }

// 二值形状 + 一次 3×3 均值，给边缘一点抗锯齿
var solid = [Double](repeating: 0, count: w*h)
for i in 0..<(w*h) { solid[i] = keep[i] ? 1 : 0 }
for i in 0..<(w*h*4) { buf[i] = 0 }   // 下面的 3×3 循环够不到最外一圈，先清干净
for y in 1..<(h-1) {
    for x in 1..<(w-1) {
        var s = 0.0
        for dy in -1...1 { for dx in -1...1 { s += solid[(y+dy)*w + x+dx] } }
        let i = y*w + x
        let a8 = UInt8((min(1, max(0, s/9 * inside[i]))*255).rounded())
        buf[i*4] = a8; buf[i*4+1] = a8; buf[i*4+2] = a8; buf[i*4+3] = a8
    }
}

let octx = CGContext(data: nil, width: outSize, height: outSize, bitsPerComponent: 8, bytesPerRow: 0,
                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
octx.interpolationQuality = .high
octx.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
try! NSBitmapImageRep(cgImage: octx.makeImage()!)
    .representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("wrote \(a[2])")
