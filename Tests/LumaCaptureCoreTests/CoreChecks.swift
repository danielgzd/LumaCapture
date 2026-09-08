import Foundation
import CoreGraphics
import LumaCaptureCore

enum CoreChecks {
    struct Check {
        let name: String
        let run: () throws -> Void
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let all: [Check] = [
        Check(name: "negative display and reversed drag geometry", run: regionClamping),
        Check(name: "empty and invalid selections", run: invalidRegions),
        Check(name: "AppKit to display-local coordinate conversion", run: displayCoordinates),
        Check(name: "Retina pixels and even video dimensions", run: pixelDimensions),
        Check(name: "history persistence and Unicode paths", run: historyRoundTrip),
        Check(name: "history ordering and capacity", run: historyCapacity),
        Check(name: "missing and corrupted history", run: corruptHistory),
        Check(name: "history write failure is surfaced", run: historyWriteFailure),
        Check(name: "same-second filename collisions and extension safety", run: filenameSafety)
    ]

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func regionClamping() throws {
        let leftScreen = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let clipped = CaptureGeometry.normalizedRegion(CGRect(x: -1500, y: -200, width: 300, height: 400), within: leftScreen)
        try expect(clipped == CGRect(x: -1440, y: -100, width: 240, height: 300), "Selection must intersect the negative-coordinate display.")
        let reversed = CaptureGeometry.normalizedRegion(CGRect(x: -200, y: 200, width: -300, height: -100), within: leftScreen)
        try expect(reversed == CGRect(x: -500, y: 100, width: 300, height: 100), "Dragging up/left must produce the same positive-size region.")
        try expect(CaptureGeometry.normalizedRegion(leftScreen, within: leftScreen) == leftScreen, "A full-display selection must retain its exact bounds.")
    }

    static func invalidRegions() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        for rect in [CGRect.zero, CGRect(x: 1, y: 1, width: 1, height: 50),
                     CGRect(x: 100, y: 0, width: 50, height: 50),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20),
                     CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)] {
            try expect(CaptureGeometry.normalizedRegion(rect, within: bounds) == nil, "Invalid selection was accepted: \(rect)")
        }
        try expect(CaptureGeometry.normalizedRegion(CGRect(x: 0, y: 0, width: 2, height: 2), within: bounds) != nil, "Minimum valid selection should be accepted.")
        try expect(CaptureGeometry.normalizedRegion(bounds, within: bounds, minimumSize: 0) == nil, "Invalid minimum size must be rejected.")
    }

    static func displayCoordinates() throws {
        let left = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let selection = CGRect(x: -1340, y: 200, width: 400, height: 300)
        try expect(CaptureGeometry.localTopLeftRect(from: selection, screenFrame: left) == CGRect(x: 100, y: 300, width: 400, height: 300), "Vertical origin must flip relative to the selected display, including negative coordinates.")
        let above = CGRect(x: 0, y: 900, width: 1280, height: 800)
        try expect(CaptureGeometry.localTopLeftRect(from: above, screenFrame: above) == CGRect(x: 0, y: 0, width: 1280, height: 800), "A vertically arranged display must have its own local origin.")
    }

    static func pixelDimensions() throws {
        let logical = CGSize(width: 300.5, height: 200.5)
        try expect(CaptureGeometry.pixelSize(for: logical, scale: 2) == CGSize(width: 601, height: 401), "Retina screenshots must preserve physical pixels.")
        try expect(CaptureGeometry.pixelSize(for: logical, scale: 2, even: true) == CGSize(width: 600, height: 400), "Video dimensions must both be even.")
        try expect(CaptureGeometry.pixelSize(for: CGSize(width: 1, height: 1), scale: 1, even: true) == CGSize(width: 2, height: 2), "Minimum encoded frame is two pixels per dimension.")
        try expect(CaptureGeometry.pixelSize(for: logical, scale: -1) == .zero, "Negative scale must be rejected.")
        try expect(CaptureGeometry.pixelSize(for: CGSize(width: CGFloat.infinity, height: 20), scale: 1) == .zero, "Non-finite image dimensions must be rejected.")
    }

    static func historyRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let repository = HistoryRepository(fileURL: directory.appendingPathComponent("nested/history.json"))
            let record = CaptureRecord(url: directory.appendingPathComponent("截图 含空格 #1.png"), kind: .screenshot, createdAt: Date(timeIntervalSince1970: 1000))
            try repository.save([record])
            let loaded = try repository.load()
            try expect(loaded == [record], "History must preserve IDs, Unicode file URLs, kind and date.")
            try repository.save([])
            let empty = try repository.load()
            try expect(empty.isEmpty, "Clearing history must persist an empty list.")
        }
    }

    static func historyCapacity() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let records = [1, 3, 2].map { index in
                CaptureRecord(url: directory.appendingPathComponent("\(index).mp4"), kind: .recording, createdAt: Date(timeIntervalSince1970: Double(index)))
            }
            try HistoryRepository(fileURL: file, limit: 2).save(records)
            let loaded = try HistoryRepository(fileURL: file).load()
            try expect(loaded.map(\.createdAt) == [Date(timeIntervalSince1970: 3), Date(timeIntervalSince1970: 2)], "History must save newest first and enforce its capacity on disk.")
            let limited = try HistoryRepository(fileURL: file, limit: 1).load()
            try expect(limited.count == 1 && limited.first?.createdAt == Date(timeIntervalSince1970: 3), "Read capacity must also be enforced.")
        }
    }

    static func corruptHistory() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let repository = HistoryRepository(fileURL: file)
            let firstLaunch = try repository.load()
            try expect(firstLaunch.isEmpty, "First launch should have empty history.")
            let invalid = Data("{ damaged history".utf8)
            try invalid.write(to: file)
            var surfaced = false
            do { _ = try repository.load() } catch { surfaced = true }
            try expect(surfaced, "Corrupted history must surface an error instead of silently disappearing.")
            let preserved = try Data(contentsOf: file)
            try expect(preserved == invalid, "Loading corrupt history must preserve the file for recovery.")
        }
    }

    static func historyWriteFailure() throws {
        try withTemporaryDirectory { directory in
            let blocker = directory.appendingPathComponent("not-a-directory")
            try Data([1, 2, 3]).write(to: blocker)
            let repository = HistoryRepository(fileURL: blocker.appendingPathComponent("history.json"))
            var surfaced = false
            do { try repository.save([]) } catch { surfaced = true }
            try expect(surfaced, "An unwritable destination must return a failure.")
            let preserved = try Data(contentsOf: blocker)
            try expect(preserved == Data([1, 2, 3]), "Failure must leave existing user data intact.")
        }
    }

    static func filenameSafety() throws {
        try withTemporaryDirectory { directory in
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let urls = (0..<200).map { _ in CaptureFileNaming.makeURL(directory: directory, kind: .screenshot, extension: "PNG", date: date) }
            try expect(Set(urls).count == 200, "Two hundred same-second captures must receive distinct names.")
            try expect(urls.allSatisfy { $0.pathExtension == "png" && $0.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path }, "Names must stay in the selected directory.")
            let first = urls[0]
            try Data([7, 8, 9]).write(to: first)
            let next = CaptureFileNaming.makeURL(directory: directory, kind: .screenshot, extension: "PNG", date: date)
            try expect(next != first, "A subsequent capture must not reuse an existing path.")
            let preserved = try Data(contentsOf: first)
            try expect(preserved == Data([7, 8, 9]), "Filename generation must not alter existing files.")
            let sanitized = CaptureFileNaming.makeURL(directory: directory, kind: .recording, extension: "../../MP4", date: date)
            try expect(sanitized.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && sanitized.pathExtension == "mp4", "An extension must not escape the destination.")
            let fallback = CaptureFileNaming.makeURL(directory: directory, kind: .recording, extension: "../", date: date)
            try expect(fallback.pathExtension == "dat", "Empty sanitized extensions need a safe fallback.")
        }
    }
}
