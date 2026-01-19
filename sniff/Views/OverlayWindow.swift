//
//  OverlayWindow.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import AppKit

class OverlayWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .titled], backing: .buffered, defer: true)
        NSApp.setActivationPolicy(.accessory)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        styleMask.insert(.resizable)
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    func setScreenshotInclusion(_ include: Bool) {
        sharingType = include ? .readOnly : .none
        level = include ? .floating : .screenSaver
    }
}

