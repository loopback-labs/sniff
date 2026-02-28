//
//  DragHandleView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 21/01/26.
//

import SwiftUI
import AppKit

struct WindowKey: EnvironmentKey {
  static let defaultValue: NSWindow? = nil
}

extension EnvironmentValues {
  var overlayWindow: NSWindow? {
    get { self[WindowKey.self] }
    set { self[WindowKey.self] = newValue }
  }
}

struct DragHandleView: View {
  var body: some View {
    DragHandleRepresentable()
      .frame(width: 24, height: 24)
  }
}

struct DragHandleRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> DragHandleNSView {
    let view = DragHandleNSView()
    return view
  }

  func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

final class DragHandleNSView: NSView {
  private let imageView: NSImageView
  
  override init(frame frameRect: NSRect) {
    imageView = NSImageView()
    super.init(frame: frameRect)
    setupView()
  }
  
  required init?(coder: NSCoder) {
    imageView = NSImageView()
    super.init(coder: coder)
    setupView()
  }
  
  private func setupView() {
    wantsLayer = true
    
    if let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag") {
      let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
      imageView.image = image.withSymbolConfiguration(config)
      imageView.contentTintColor = .secondaryLabelColor
    }
    
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16)
    ])
  }
  
  override var acceptsFirstResponder: Bool { true }
  
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
  
  override func mouseDown(with event: NSEvent) {
    NSCursor.closedHand.set()
    window?.performDrag(with: event)
  }
  
  override func mouseUp(with event: NSEvent) {
    NSCursor.openHand.set()
  }
  
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
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
    NSCursor.openHand.set()
  }
  
  override func mouseExited(with event: NSEvent) {
    NSCursor.arrow.set()
  }
}

struct ResizeHandleView: View {
  var body: some View {
    ResizeHandleRepresentable()
      .frame(width: 20, height: 20)
  }
}

struct ResizeHandleRepresentable: NSViewRepresentable {
  func makeNSView(context: Context) -> ResizeHandleNSView {
    ResizeHandleNSView()
  }
  
  func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {}
}

final class ResizeHandleNSView: NSView {
  private let imageView: NSImageView
  private var startFrame: NSRect?
  private var startMouseLocation: NSPoint?
  
  override init(frame frameRect: NSRect) {
    imageView = NSImageView()
    super.init(frame: frameRect)
    setupView()
  }
  
  required init?(coder: NSCoder) {
    imageView = NSImageView()
    super.init(coder: coder)
    setupView()
  }
  
  private func setupView() {
    wantsLayer = true
    
    if let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize") {
      let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
      imageView.image = image.withSymbolConfiguration(config)
      imageView.contentTintColor = .secondaryLabelColor
      imageView.alphaValue = 0.6
    }
    
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 14),
      imageView.heightAnchor.constraint(equalToConstant: 14)
    ])
  }
  
  override var acceptsFirstResponder: Bool { true }
  
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
  
  override func mouseDown(with event: NSEvent) {
    startFrame = window?.frame
    startMouseLocation = NSEvent.mouseLocation
    NSCursor.resizeUpDown.set()
  }
  
  override func mouseDragged(with event: NSEvent) {
    guard let window = window,
          let startFrame = startFrame,
          let startMouseLocation = startMouseLocation else { return }
    
    let currentLocation = NSEvent.mouseLocation
    let deltaX = currentLocation.x - startMouseLocation.x
    let deltaY = currentLocation.y - startMouseLocation.y
    
    let minWidth = window.minSize.width
    let minHeight = window.minSize.height
    
    // Resize from bottom-right corner: width increases right, height increases down (origin moves down)
    let newWidth = max(minWidth, startFrame.width + deltaX)
    let newHeight = max(minHeight, startFrame.height - deltaY)
    let newOriginY = startFrame.origin.y + (startFrame.height - newHeight)
    
    let newFrame = NSRect(
      x: startFrame.origin.x,
      y: newOriginY,
      width: newWidth,
      height: newHeight
    )
    window.setFrame(newFrame, display: true)
  }
  
  override func mouseUp(with event: NSEvent) {
    startFrame = nil
    startMouseLocation = nil
    NSCursor.arrow.set()
  }
  
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeUpDown)
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
    imageView.alphaValue = 1.0
    NSCursor.resizeUpDown.set()
  }
  
  override func mouseExited(with event: NSEvent) {
    imageView.alphaValue = 0.6
    NSCursor.arrow.set()
  }
}
