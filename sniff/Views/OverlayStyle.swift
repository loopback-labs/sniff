//
//  OverlayStyle.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

extension View {
    func overlayCardStyle() -> some View {
        self
            .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
