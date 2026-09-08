#if canImport(XCTest)
import XCTest

final class CoreTests: XCTestCase {
    func testRegionClamping() throws { try CoreChecks.regionClamping() }
    func testInvalidRegions() throws { try CoreChecks.invalidRegions() }
    func testDisplayCoordinates() throws { try CoreChecks.displayCoordinates() }
    func testPixelDimensions() throws { try CoreChecks.pixelDimensions() }
    func testHistoryRoundTrip() throws { try CoreChecks.historyRoundTrip() }
    func testHistoryCapacity() throws { try CoreChecks.historyCapacity() }
    func testCorruptHistory() throws { try CoreChecks.corruptHistory() }
    func testHistoryWriteFailure() throws { try CoreChecks.historyWriteFailure() }
    func testFilenameSafety() throws { try CoreChecks.filenameSafety() }
}
#endif
