//
//  OverlayWindow.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import AppKit

class OverlayWindow: NSPanel {
    /// SwiftUI `.global`-space rects (top-left origin) of the controls that should stay clickable.
    var interactiveRegions: [CGRect] = []

    init(config: WindowConfiguration, screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let frame = config.calculateFrame(for: targetScreen)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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

    /// Flips the whole-window `ignoresMouseEvents` flag based on cursor position, so only the
    /// registered control regions capture clicks and everything else passes through to the app behind.
    func refreshClickThrough(mouseScreenPoint: NSPoint, forceInteractive: Bool) {
        guard !forceInteractive else {
            ignoresMouseEvents = false
            return
        }
        guard let contentView else {
            ignoresMouseEvents = true
            return
        }
        let windowPoint = convertPoint(fromScreen: mouseScreenPoint)
        // AppKit window coords are bottom-left origin; SwiftUI `.global` is top-left.
        let flippedPoint = CGPoint(x: windowPoint.x, y: contentView.bounds.height - windowPoint.y)
        ignoresMouseEvents = !interactiveRegions.contains { $0.contains(flippedPoint) }
    }
}
