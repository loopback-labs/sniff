//
//  QADisplayView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

struct QADisplayView: View {
    let item: QAItem
    
    private var answerText: String {
        item.answer?.isEmpty == false ? item.answer! : "Generating answer..."
    }
    
    private var isLoading: Bool {
        item.answer?.isEmpty != false
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerRow(icon: "questionmark.circle.fill", color: .blue, title: "Question")
                Text(item.question)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                HStack {
                    headerRow(icon: "bubble.left.and.bubble.right.fill", color: .green, title: "Answer")
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
                
                if let attributedString = try? AttributedString(markdown: answerText) {
                    Text(attributedString)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(answerText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .frame(minHeight: 100)
        .overlayCardStyle()
    }
    
    private func headerRow(icon: String, color: Color, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
