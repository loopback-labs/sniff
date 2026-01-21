//
//  OverlayWindow.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import AppKit

class OverlayWindow: NSWindow {
    init(config: WindowConfiguration, screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let frame = config.calculateFrame(for: targetScreen)
        
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        NSApp.setActivationPolicy(.accessory)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        styleMask.insert(.resizable)
        
        // Allow clicks to pass through to apps behind, but tracking areas
        // in interactive views will set this to false when hovered
        ignoresMouseEvents = true
        
        setFrame(frame, display: true)
        minSize = config.size
        maxSize = targetScreen.visibleFrame.size
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    func setScreenshotInclusion(_ include: Bool) {
        sharingType = include ? .readOnly : .none
        level = include ? .floating : .screenSaver
    }
}

