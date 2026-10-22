// 1024px 원본 아이콘으로 AppIcon 세트를 만든다.
// iOS: 불투명 1024 한 장 (시스템이 모서리를 깎는다)
// macOS: 둥근 사각형 + 여백 (Big Sur 이후 맥 아이콘 격자: 1024 캔버스에 824 크기, 반경 185)
// 사용: swift scripts/make-app-icon.swift <원본.png> <AppIcon.appiconset 경로>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
	print("사용: swift make-app-icon.swift <원본.png> <AppIcon.appiconset>"); exit(1)
}
let out = URL(fileURLWithPath: args[2])

func write(_ size: Int, _ name: String, opaque: Bool, macShape: Bool) {
	let space = CGColorSpace(name: CGColorSpace.sRGB)!
	let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
	let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
	ctx.interpolationQuality = .high
	let s = CGFloat(size)
	var rect = CGRect(x: 0, y: 0, width: s, height: s)
	if macShape {
		let inset = s * (1024 - 824) / 2 / 1024
		rect = rect.insetBy(dx: inset, dy: inset)
		let path = CGPath(roundedRect: rect, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
		// 맥 아이콘 아래쪽 그림자
		ctx.saveGState()
		ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024, color: CGColor(gray: 0, alpha: 0.3))
		ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
		ctx.restoreGState()
		ctx.addPath(path); ctx.clip()
	}
	ctx.draw(source, in: rect)
	let image = ctx.makeImage()!
	let rep = NSBitmapImageRep(cgImage: image)
	try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

var images: [[String: String]] = []
write(1024, "ios-1024.png", opaque: true, macShape: false)
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
for base in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = "mac-\(base)@\(scale)x.png"
		write(base * scale, name, opaque: false, macShape: true)
		images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
	}
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
	.write(to: out.appendingPathComponent("Contents.json"))
print("AppIcon: \(images.count)개")
