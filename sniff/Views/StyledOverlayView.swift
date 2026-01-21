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
        .background(
            InteractiveBackgroundView()
                .background(Color(NSColor.controlBackgroundColor).opacity(config.backgroundOpacity))
        )
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

/// NSView-based background that enables mouse events on hover
struct InteractiveBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> InteractiveNSView {
        InteractiveNSView()
    }
    
    func updateNSView(_ nsView: InteractiveNSView, context: Context) {}
}

final class InteractiveNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTracking()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }
    
    private func setupTracking() {
        wantsLayer = true
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        window?.ignoresMouseEvents = false
    }
    
    override func mouseExited(with event: NSEvent) {
        window?.ignoresMouseEvents = true
    }
}
