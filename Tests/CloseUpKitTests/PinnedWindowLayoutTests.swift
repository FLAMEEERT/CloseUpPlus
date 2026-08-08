import Foundation
import Testing

@testable import CloseUpKit

@Suite("PinnedWindowLayout")
struct PinnedWindowLayoutTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cascadeOffset = CGSize(width: 60, height: 60)

    @Test("source CG frame converts to the identical AppKit screen location")
    func sourceFrameConversion() throws {
        let source = CGRect(x: 120, y: 80, width: 900, height: 600)
        let appKit = try #require(PinnedWindowLayout.appKitFrame(
            forCoreGraphicsFrame: source,
            pivotHeight: 1200
        ))

        #expect(appKit == CGRect(x: 120, y: 520, width: 900, height: 600))
        #expect(PinnedWindowLayout.coreGraphicsFrame(
            forAppKitFrame: appKit,
            pivotHeight: 1200
        ) == source)
    }

    @Test("invalid source frame conversion fails safely")
    func invalidSourceFrameConversion() {
        #expect(PinnedWindowLayout.appKitFrame(
            forCoreGraphicsFrame: .zero,
            pivotHeight: 1200
        ) == nil)
        #expect(PinnedWindowLayout.coreGraphicsFrame(
            forAppKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pivotHeight: .nan
        ) == nil)
    }

    @Test("16:9 source fits the 35 percent display box and keeps its aspect ratio")
    func landscapeAspectFit() throws {
        let frame = try #require(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 16.0 / 9.0,
            cascadeOffset: cascadeOffset
        ))

        #expect(frame.width == display.width * 0.35)
        #expect(abs(frame.height - frame.width * 9.0 / 16.0) < 0.000_001)
        #expect(frame.maxX == display.maxX)
        #expect(frame.maxY == display.maxY)
        #expect(display.contains(frame))
    }

    @Test("portrait source fits by height without distorting its aspect ratio")
    func portraitAspectFit() throws {
        let frame = try #require(PinnedWindowLayout.initialFrame(
            visibleDisplayFrame: display,
            sourceAspectRatio: 9.0 / 16.0,
            cascadeOffset: cascadeOffset
        ))

        #expect(frame.height == display.height * 0.35)
        #expect(frame.width == frame.height * 9.0 / 16.0)
        #expect(display.contains(frame))
    }

    @Test("square source fits the smaller display dimension")
    func squareAspectFit() throws {
        let frame = try #require(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 1,
            cascadeOffset: cascadeOffset
        ))

        #expect(frame.width == display.height * 0.35)
        #expect(frame.height == frame.width)
        #expect(display.contains(frame))
    }

    @Test("successive mirrors cascade down-left from the upper-right anchor")
    func cascadesDownLeft() throws {
        let first = try #require(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 16.0 / 9.0,
            cascadeOffset: cascadeOffset
        ))
        let second = try #require(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 16.0 / 9.0,
            existingMirrorFrames: [first],
            cascadeOffset: cascadeOffset
        ))

        #expect(second.minX < first.minX)
        #expect(second.minY < first.minY)
        #expect(display.contains(second))
        #expect(!second.intersects(first))
    }

    @Test("cascade wraps after an edge collision and stays on the creation display")
    func wrapsAndClamps() throws {
        let smallDisplay = CGRect(x: 20, y: 40, width: 300, height: 300)
        let first = try #require(PinnedWindowLayout.initialFrame(
            in: smallDisplay,
            sourceAspectRatio: 1,
            cascadeOffset: CGSize(width: 100, height: 100)
        ))
        let second = try #require(PinnedWindowLayout.initialFrame(
            in: smallDisplay,
            sourceAspectRatio: 1,
            existingMirrorFrames: [first],
            cascadeOffset: CGSize(width: 100, height: 100)
        ))
        let third = try #require(PinnedWindowLayout.initialFrame(
            in: smallDisplay,
            sourceAspectRatio: 1,
            existingMirrorFrames: [first, second],
            cascadeOffset: CGSize(width: 100, height: 100)
        ))

        #expect(smallDisplay.contains(first))
        #expect(smallDisplay.contains(second))
        #expect(smallDisplay.contains(third))
        #expect(third != first)
        #expect(third != second)
    }

    @Test("aspect-fit updates use only the chosen panel frame")
    func laterAspectFit() throws {
        let panel = CGRect(x: 200, y: 100, width: 500, height: 400)
        let fitted = try #require(PinnedWindowLayout.aspectFitFrame(
            sourceAspectRatio: 16.0 / 9.0,
            inside: panel
        ))

        #expect(panel.contains(fitted))
        #expect(fitted.width == panel.width)
        #expect(fitted.height == fitted.width * 9.0 / 16.0)
        #expect(fitted.midX == panel.midX)
        #expect(fitted.midY == panel.midY)
    }

    @Test("invalid display, ratio, and cascade inputs fail safely")
    func invalidInputs() {
        #expect(PinnedWindowLayout.initialFrame(
            in: .zero,
            sourceAspectRatio: 16.0 / 9.0,
            cascadeOffset: cascadeOffset
        ) == nil)
        #expect(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 0,
            cascadeOffset: cascadeOffset
        ) == nil)
        #expect(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: CGFloat(Double.nan),
            cascadeOffset: cascadeOffset
        ) == nil)
        #expect(PinnedWindowLayout.initialFrame(
            in: display,
            sourceAspectRatio: 16.0 / 9.0,
            cascadeOffset: CGSize(width: CGFloat(Double.nan), height: 20)
        ) == nil)
    }
}
