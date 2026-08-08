import CloseUpKit
import SwiftUI

/// Per-session hover state for the overlay cluster. The overlay window ignores
/// mouse events (it is passive — the event tap handles clicks), so SwiftUI hover
/// cannot fire; the engine's mouse-tracking loop sets `hoveredIndex` instead.
@MainActor
@Observable
final class OverlayHoverState {
    var hoveredIndex: Int?
}

/// The visual button cluster drawn over the hovered Mission Control thumbnail.
/// Neutral gray-white circles (not the vivid stoplight colors) with no
/// surrounding box, matching native Mission Control. The
/// glyph is always shown — with monochrome buttons it is the only thing that
/// distinguishes close / minimize / zoom — and the hovered button lifts slightly.
/// Clicks are detected by the engine's EventTap against OverlayGeometry, never by
/// these views.
struct OverlayClusterView: View {
    let controls: [OverlayControl]
    let locale: Locale
    let hoverState: OverlayHoverState

    var body: some View {
        HStack(spacing: OverlayGeometry.buttonSpacing) {
            ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                OverlayButtonView(
                    control: control,
                    isHovered: hoverState.hoveredIndex == index
                )
            }
        }
        .padding(OverlayGeometry.clusterPadding)
        .environment(\.locale, locale)
        .fixedSize()
    }
}

private struct OverlayButtonView: View {
    let control: OverlayControl
    let isHovered: Bool

    var body: some View {
        ZStack {
            Circle().fill(DS.Palette.overlayButtonFill)
            Image(systemName: control.symbolName)
                .font(.system(size: OverlayGeometry.symbolSize, weight: .bold))
                .foregroundStyle(DS.Palette.overlayButtonSymbol)
        }
        .frame(width: OverlayGeometry.buttonSize, height: OverlayGeometry.buttonSize)
        .overlay(Circle().strokeBorder(DS.Palette.overlayButtonBorder, lineWidth: DS.Overlay.buttonBorderWidth))
        .shadow(color: DS.Palette.overlayButtonShadow, radius: DS.Overlay.buttonShadowRadius, y: DS.Overlay.buttonShadowYOffset)
        .opacity(control.isEnabled ? 1.0 : 0.45)
        .scaleEffect(isHovered ? DS.Overlay.hoverLift : 1.0)
        .animation(DS.Motion.overlay, value: isHovered)
        .disabled(!control.isEnabled)
        .accessibilityLabel(LocalizedStringKey(control.titleKey))
        .help(LocalizedStringKey(control.titleKey))
    }
}
