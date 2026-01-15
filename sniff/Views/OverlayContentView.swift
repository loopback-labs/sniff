//
//  OverlayContentView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

struct OverlayContentView: View {
    @ObservedObject var qaManager: QAManager
    
    var body: some View {
        VStack(spacing: 0) {
            if let currentItem = qaManager.currentItem {
                QADisplayView(item: currentItem)
                    .frame(width: 400)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "questionmark.bubble")
                            .foregroundColor(.secondary)
                        Text("Sniff - Ready")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if qaManager.items.isEmpty {
                        Text("Waiting for questions...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(qaManager.items.count) question(s) detected")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
                .padding(8)
                .frame(width: 250)
            }
            
            if qaManager.items.count > 1 {
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
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .background(Color.clear)
    }
}
