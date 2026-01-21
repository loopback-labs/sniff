//
//  QADisplayView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI
import Textual

struct QADisplayView: View {
    let item: QAItem
    
    private var answerText: String {
        item.answer?.isEmpty == false ? item.answer! : "Generating answer..."
    }
    
    private var isLoading: Bool {
        item.answer?.isEmpty != false
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DragHandleView()
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.blue)
                Text("Question")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.question)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Divider()
                    
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.green)
                        Text("Answer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Spacer()
                    }
                    
                    StructuredText(markdown: answerText)
                        .font(.system(size: 12))
                        .textual.structuredTextStyle(.gitHub)
                        .textual.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 140)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .overlay(alignment: .bottomTrailing) {
            ResizeHandleView()
                .padding(6)
        }
    }
    
}
