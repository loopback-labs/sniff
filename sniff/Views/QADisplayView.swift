//
//  QADisplayView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

struct QADisplayView: View {
    let item: QAItem
    @State private var showingQuestion = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: { showingQuestion.toggle() }) {
                    Image(systemName: showingQuestion ? "questionmark.circle.fill" : "bubble.left.and.bubble.right.fill")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                Text(showingQuestion ? "Question" : "Answer")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if item.answer == nil {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            
            ScrollView {
                Text(showingQuestion ? item.question : (item.answer ?? "Generating answer..."))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
