import CoreGraphics
import XCTest
@testable import NeedsYouShared

final class IslandLayoutTests: XCTestCase {
    func testPanelFrameLandsOnWholePixels() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for scale: CGFloat in [1, 2, 3] {
            for cx in stride(from: CGFloat(755.1), through: 757.9, by: 0.13) {
                let f = IslandLayout.panelFrame(screen: screen, centerX: cx, size: CGSize(width: 640, height: 186.3), scale: scale)
                for v in [f.minX, f.maxX, f.minY, f.maxY] {
                    XCTAssertEqual((v * scale).rounded(), v * scale, accuracy: 1e-9, "scale \(scale) cx \(cx)")
                }
                XCTAssertEqual(f.maxY, 982)
                XCTAssertLessThanOrEqual(abs(f.midX - cx), 1 / scale)
            }
        }
    }

    func testSameScreenGivesSameFrame() {
        let screen = CGRect(x: -1728, y: 0, width: 1728, height: 1117)
        let a = IslandLayout.panelFrame(screen: screen, centerX: -864.25, size: CGSize(width: 640, height: 150), scale: 2)
        let b = IslandLayout.panelFrame(screen: screen, centerX: -864.25, size: CGSize(width: 640, height: 150), scale: 2)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.maxY, 1117)
    }

    func testNotchFromMenuBarAreas() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let l = CGRect(x: 0, y: 950, width: 663.5, height: 32), r = CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
        let n = IslandLayout.notch(screen: screen, leftArea: l, rightArea: r, scale: 2)
        XCTAssertEqual(n?.width, 185)
        XCTAssertEqual(n?.centerX, 756)
        XCTAssertNil(IslandLayout.notch(screen: screen, leftArea: nil, rightArea: r, scale: 2))
        // The built-in screen left of a main external one: same notch, moved with the screen.
        let moved = IslandLayout.notch(screen: screen.offsetBy(dx: -1512, dy: 0), leftArea: l, rightArea: r, scale: 2)
        XCTAssertEqual(moved?.width, 185)
        XCTAssertEqual(moved?.centerX, 756 - 1512)
    }
}
