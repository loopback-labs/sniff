//
//  OverlayContentView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

// Wrapper that applies config-based styling
struct QAOverlayContent: View {
    @ObservedObject var qaManager: QAManager
    
    var body: some View {
        StyledOverlayView(
            config: .qaOverlay,
            icon: "questionmark.bubble"
        ) {
            QAContentView(qaManager: qaManager)
        }
    }
}

// Pure content view - just the Q&A display logic
struct QAContentView: View {
    @ObservedObject var qaManager: QAManager
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var draft: String = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let currentItem = qaManager.currentItem {
                QADisplayView(item: currentItem)
                    .padding(8)
            } else {
                emptyStateView
            }

            if qaManager.items.count > 1 {
                navigationControls
            }

            composer
        }
        .onChange(of: coordinator.askComposerFocusToken) { _, _ in
            isComposerFocused = true
        }
        .onChange(of: isComposerFocused) { _, focused in
            coordinator.isAskComposerFocused = focused
        }
    }

    private var composer: some View {
        TextField("Ask sniff…", text: $draft)
            .textFieldStyle(.plain)
            .font(.caption)
            .padding(8)
            .focused($isComposerFocused)
            .onSubmit {
                let text = draft
                draft = ""
                coordinator.runMode(.ask, typedText: text)
            }
    }
    
    private var emptyStateView: some View {
        Text(qaManager.items.isEmpty ? "Waiting for questions..." : "\(qaManager.items.count) question(s) detected")
            .font(.caption2)
            .foregroundColor(qaManager.items.isEmpty ? .secondary : .blue)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var navigationControls: some View {
        HStack(spacing: 8) {
            Button(action: { qaManager.goToFirst() }) {
                Image(systemName: "chevron.left.2")
            }
            .disabled(!qaManager.canGoPrevious)
            
            Button(action: { qaManager.goToPrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!qaManager.canGoPrevious)
            
            Text("\(qaManager.currentIndex + 1) / \(qaManager.items.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 50)
            
            Button(action: { qaManager.goToNext() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!qaManager.canGoNext)
            
            Button(action: { qaManager.goToLast() }) {
                Image(systemName: "chevron.right.2")
            }
            .disabled(!qaManager.canGoNext)
        }
        .buttonStyle(.plain)
        .padding(8)
    }
}
