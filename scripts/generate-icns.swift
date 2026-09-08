import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate-icns <input.iconset> <output.icns>\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_16x16@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_128x128@2x.png"),
    ("ic09", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png")
]

func bigEndian(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return Data(bytes: &encoded, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for (type, filename) in entries {
    let png = try Data(contentsOf: input.appendingPathComponent(filename))
    guard let typeData = type.data(using: .ascii), typeData.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
    body.append(typeData)
    body.append(bigEndian(UInt32(png.count + 8)))
    body.append(png)
}
var result = Data("icns".utf8)
result.append(bigEndian(UInt32(body.count + 8)))
result.append(body)
try result.write(to: output, options: .atomic)
