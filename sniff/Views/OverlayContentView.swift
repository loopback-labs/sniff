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
        VStack(spacing: 8) {
            if let currentItem = qaManager.currentItem {
                QADisplayView(item: currentItem)
            } else {
                emptyStateView
            }

            if qaManager.items.count > 1 {
                navigationControls
            }

            Divider()

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
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Ask sniff… (⌘⇧K)", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isComposerFocused)
                .onSubmit(submitDraft)

            Button(action: submitDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(draft.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func submitDraft() {
        let text = draft
        draft = ""
        coordinator.runMode(.ask, typedText: text)
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.bubble")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Waiting for questions…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("⌘⇧A answers the last question · ⌘⇧Q solves what's on screen")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
