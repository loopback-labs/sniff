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
        .background(Color(NSColor.controlBackgroundColor).opacity(config.backgroundOpacity))
        .overlay(alignment: .bottomTrailing) {
            if config.showResizeHandle {
                ResizeHandleView()
                    .padding(6)
            }
        }
    }
    
    private var header: some View {
        HStack {
            DragHandleView()
            Image(systemName: icon)
                .foregroundColor(iconColor)
            Text(config.name)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let trailing = headerTrailing {
                trailing
            }
        }
    }
}
