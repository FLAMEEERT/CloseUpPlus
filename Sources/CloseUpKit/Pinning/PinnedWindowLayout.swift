import Foundation

/// Pure coordinate conversion plus the legacy compact-mirror layout helpers.
///
/// The conversion entry points bridge CoreGraphics source geometry to AppKit
/// panel geometry. The compact-layout helpers remain for compatibility, but
/// the live Topit-style Pin path no longer uses them.
public enum PinnedWindowLayout {
    public static let targetDisplayFraction: CGFloat = 0.35
    public static let defaultCascadeOffset = CGSize(width: 24, height: 24)

    /// Convert a source window's CoreGraphics global frame (top-left origin)
    /// into the AppKit global frame used by `NSWindow` (bottom-left origin).
    public static func appKitFrame(
        forCoreGraphicsFrame frame: CGRect,
        pivotHeight: CGFloat
    ) -> CGRect? {
        guard let frame = validRect(frame), pivotHeight.isFinite else { return nil }
        return CGRect(
            x: frame.minX,
            y: pivotHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Inverse of `appKitFrame(forCoreGraphicsFrame:pivotHeight:)`.
    public static func coreGraphicsFrame(
        forAppKitFrame frame: CGRect,
        pivotHeight: CGFloat
    ) -> CGRect? {
        guard let frame = validRect(frame), pivotHeight.isFinite else { return nil }
        return CGRect(
            x: frame.minX,
            y: pivotHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Compute the first frame for a mirror on the display where Pin was
    /// invoked. The target box is 35% of the display in each dimension; the
    /// source aspect ratio is fit inside that box.
    public static func initialFrame(
        in displayFrame: CGRect,
        sourceAspectRatio: CGFloat,
        existingMirrorFrames: [CGRect] = [],
        cascadeOffset: CGSize = PinnedWindowLayout.defaultCascadeOffset,
        targetFraction: CGFloat = PinnedWindowLayout.targetDisplayFraction
    ) -> CGRect? {
        guard let display = validRect(displayFrame),
              let offset = validOffset(cascadeOffset),
              targetFraction.isFinite,
              targetFraction > 0,
              targetFraction <= 1,
              let size = aspectFitSize(
                  sourceAspectRatio: sourceAspectRatio,
                  inside: CGSize(
                      width: display.width * targetFraction,
                      height: display.height * targetFraction
                  )
              )
        else { return nil }

        let base = CGRect(
            x: display.maxX - size.width,
            y: display.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let existing = existingMirrorFrames.compactMap(validRect)
        let horizontalSlots = slotCount(
            availableLength: display.width - size.width,
            step: offset.width
        )
        let verticalSlots = slotCount(
            availableLength: display.height - size.height,
            step: offset.height
        )
        let diagonalSlots = max(1, min(horizontalSlots, verticalSlots))
        let totalSlots = max(1, horizontalSlots * verticalSlots)
        let startIndex = existing.count % totalSlots
        var fallback: CGRect?

        for attempt in 0..<totalSlots {
            let slotIndex = (startIndex + attempt) % totalSlots
            let (column, row) = slot(
                index: slotIndex,
                horizontalSlots: horizontalSlots,
                verticalSlots: verticalSlots,
                diagonalSlots: diagonalSlots
            )
            let candidate = clamped(
                CGRect(
                    x: base.minX - CGFloat(column) * offset.width,
                    y: base.minY - CGFloat(row) * offset.height,
                    width: size.width,
                    height: size.height
                ),
                to: display
            )

            if fallback == nil && !existing.contains(where: { $0 == candidate }) {
                fallback = candidate
            }
            if !existing.contains(where: { $0.intersects(candidate) }) {
                return candidate
            }
        }

        // A display can be completely occupied. Returning a valid clamped
        // frame is safer than failing the Pin request after all deterministic
        // slots have been exhausted.
        return fallback ?? clamped(base, to: display)
    }

    /// Same operation with a label that makes the creation-display contract
    /// explicit at call sites.
    public static func initialFrame(
        visibleDisplayFrame: CGRect,
        sourceAspectRatio: CGFloat,
        existingMirrorFrames: [CGRect] = [],
        cascadeOffset: CGSize = PinnedWindowLayout.defaultCascadeOffset,
        targetFraction: CGFloat = PinnedWindowLayout.targetDisplayFraction
    ) -> CGRect? {
        initialFrame(
            in: visibleDisplayFrame,
            sourceAspectRatio: sourceAspectRatio,
            existingMirrorFrames: existingMirrorFrames,
            cascadeOffset: cascadeOffset,
            targetFraction: targetFraction
        )
    }

    /// Aspect-fit content inside an already user-chosen panel frame. This is
    /// used after a source aspect-ratio change and never changes the panel's
    /// position or size.
    public static func aspectFitFrame(
        sourceAspectRatio: CGFloat,
        inside panelFrame: CGRect
    ) -> CGRect? {
        guard let panel = validRect(panelFrame),
              let size = aspectFitSize(
                  sourceAspectRatio: sourceAspectRatio,
                  inside: panel.size
              )
        else { return nil }

        return CGRect(
            x: panel.midX - size.width / 2,
            y: panel.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func validRect(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.width > 0,
              rect.height > 0
        else { return nil }
        return rect
    }

    private static func validOffset(_ offset: CGSize) -> CGSize? {
        guard offset.width.isFinite,
              offset.height.isFinite,
              offset.width >= 0,
              offset.height >= 0
        else { return nil }
        return offset
    }

    private static func aspectFitSize(
        sourceAspectRatio: CGFloat,
        inside box: CGSize
    ) -> CGSize? {
        guard sourceAspectRatio.isFinite,
              sourceAspectRatio > 0,
              box.width.isFinite,
              box.height.isFinite,
              box.width > 0,
              box.height > 0
        else { return nil }

        let width: CGFloat
        let height: CGFloat
        if sourceAspectRatio >= box.width / box.height {
            width = box.width
            height = box.width / sourceAspectRatio
        } else {
            height = box.height
            width = box.height * sourceAspectRatio
        }

        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func slotCount(availableLength: CGFloat, step: CGFloat) -> Int {
        guard step > 0, availableLength >= step else { return 1 }
        let count = Int(floor(availableLength / step)) + 1
        return max(1, count)
    }

    /// Slot zero is the upper-right anchor. The initial sequence moves
    /// diagonally down-left; once either edge is reached, the remaining unique
    /// grid slots are visited to wrap on the same display.
    private static func slot(
        index: Int,
        horizontalSlots: Int,
        verticalSlots: Int,
        diagonalSlots: Int
    ) -> (column: Int, row: Int) {
        guard index >= 0,
              horizontalSlots > 0,
              verticalSlots > 0
        else { return (0, 0) }

        let totalSlots = horizontalSlots * verticalSlots
        let normalizedIndex = index % totalSlots
        if normalizedIndex < diagonalSlots {
            return (normalizedIndex, normalizedIndex)
        }

        var remaining = normalizedIndex - diagonalSlots
        for row in 0..<verticalSlots {
            for column in 0..<horizontalSlots {
                if row < diagonalSlots, column == row {
                    continue
                }
                if remaining == 0 {
                    return (column, row)
                }
                remaining -= 1
            }
        }

        return (0, 0)
    }

    private static func clamped(_ frame: CGRect, to display: CGRect) -> CGRect {
        let x = min(max(frame.minX, display.minX), display.maxX - frame.width)
        let y = min(max(frame.minY, display.minY), display.maxY - frame.height)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}
