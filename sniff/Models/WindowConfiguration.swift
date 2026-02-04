//
//  WindowConfiguration.swift
//  sniff
//

import AppKit

struct WindowConfiguration {
    let name: String
    let size: NSSize
    let position: WindowPosition
    
    // Styling
    let backgroundOpacity: CGFloat
    let padding: CGFloat
    let showResizeHandle: Bool
    
    enum WindowPosition {
        case topLeft, topRight
    }
    
    // Predefined configs
    static let qaOverlay = WindowConfiguration(
        name: "Q&A",
        size: NSSize(width: 620, height: 600),
        position: .topRight,
        backgroundOpacity: 0.8,
        padding: 30,
        showResizeHandle: true
    )
    
    static let transcript = WindowConfiguration(
        name: "Transcription",
        size: NSSize(width: 600, height: 600),
        position: .topLeft,
        backgroundOpacity: 0.8,
        padding: 12,
        showResizeHandle: true
    )
    
    func calculateFrame(for screen: NSScreen) -> NSRect {
        let screenRect = screen.visibleFrame
        let padding: CGFloat = 30
        let x = position == .topLeft
            ? screenRect.minX + padding
            : screenRect.maxX - size.width - padding
        
        return NSRect(
            x: x,
            y: screenRect.maxY - size.height - padding,
            width: size.width,
            height: size.height
        )
    }
}
