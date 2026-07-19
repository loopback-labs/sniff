//
//  StyledOverlayView.swift
//  sniff
//

import SwiftUI
import AppKit

/// Global-space frames of controls that should stay clickable while the rest of the
/// overlay window is click-through. Reduce = append: every `.overlayInteractive()` view
/// along the tree contributes its frame here.
private struct InteractiveRegionsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as an interactive control: its frame is reported up to the enclosing
    /// `StyledOverlayView`, which keeps it clickable even when the rest of the window passes
    /// clicks through to the app behind it.
    func overlayInteractive() -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: InteractiveRegionsKey.self, value: [geometry.frame(in: .global)])
            }
        )
    }
}

struct StyledOverlayView<Content: View>: View {
    let config: WindowConfiguration
    let icon: String
    let iconColor: Color
    let headerTrailing: AnyView?
    @ViewBuilder let content: () -> Content

    @Environment(\.overlayWindow) private var overlayWindow

    private let cornerRadius: CGFloat = 14

    init(
        config: WindowConfiguration,
        icon: String,
        iconColor: Color = .secondary,
        headerTrailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.config = config
        self.icon = icon
        self.iconColor = iconColor
        self.headerTrailing = headerTrailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content()
        }
        .padding(config.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Faint adaptive tint only — content behind the overlay must stay readable.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if config.showResizeHandle {
                ResizeHandleView()
                    .padding(6)
                    .overlayInteractive()
            }
        }
        .onPreferenceChange(InteractiveRegionsKey.self) { rects in
            (overlayWindow as? OverlayWindow)?.interactiveRegions = rects
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DragHandleView()
                .overlayInteractive()
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(iconColor)
            Text(config.name)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            if let trailing = headerTrailing {
                trailing
            }
        }
    }
}
