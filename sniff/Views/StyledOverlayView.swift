//
//  StyledOverlayView.swift
//  sniff
//

import SwiftUI
import AppKit

struct StyledOverlayView<Content: View>: View {
    let config: WindowConfiguration
    let icon: String
    let iconColor: Color
    let headerTrailing: AnyView?
    @ViewBuilder let content: () -> Content

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
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DragHandleView()
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
