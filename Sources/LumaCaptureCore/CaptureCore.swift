import Foundation
import CoreGraphics

public enum CaptureGeometry {
    public static func normalizedRegion(_ rect: CGRect, within bounds: CGRect, minimumSize: CGFloat = 2) -> CGRect? {
        guard [rect.origin.x, rect.origin.y, rect.width, rect.height, bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy({ $0.isFinite }), minimumSize.isFinite, minimumSize > 0 else { return nil }
        let result = rect.standardized.intersection(bounds.standardized)
        guard !result.isNull, result.width >= minimumSize, result.height >= minimumSize else { return nil }
        return result
    }

    public static func pixelSize(for size: CGSize, scale: CGFloat, even: Bool = false) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0, size.width > 0, size.height > 0 else { return .zero }
        func dimension(_ value: CGFloat) -> CGFloat {
            let pixels = max(1, (value * scale).rounded())
            guard pixels.isFinite else { return 0 }
            return even ? max(2, floor(pixels / 2) * 2) : pixels
        }
        return CGSize(width: dimension(size.width), height: dimension(size.height))
    }

    /// AppKit global bottom-left coordinates -> display-local top-left points.
    public static func localTopLeftRect(from globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        let rect = globalRect.standardized
        return CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

public enum CaptureKind: String, Codable, CaseIterable {
    case screenshot, recording
}

public struct CaptureRecord: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: URL
    public var kind: CaptureKind
    public var createdAt: Date
    public init(id: UUID = UUID(), url: URL, kind: CaptureKind, createdAt: Date = Date()) {
        self.id = id; self.url = url; self.kind = kind; self.createdAt = createdAt
    }
}

public struct HistoryRepository {
    public let fileURL: URL
    public let limit: Int
    public init(fileURL: URL, limit: Int = 500) {
        self.fileURL = fileURL; self.limit = max(1, limit)
    }
    public func load() throws -> [CaptureRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return Array(try JSONDecoder().decode([CaptureRecord].self, from: Data(contentsOf: fileURL))
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
    public func save(_ records: [CaptureRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(limit)))
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum CaptureFileNaming {
    public static func makeURL(directory: URL, kind: CaptureKind, extension fileExtension: String, date: Date = Date(), id: UUID = UUID()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let name = "Luma_\(kind == .screenshot ? "Shot" : "Recording")_\(formatter.string(from: date))_\(id.uuidString.lowercased())"
        return directory.appendingPathComponent(name).appendingPathExtension(suffix.isEmpty ? "dat" : suffix)
    }
}
