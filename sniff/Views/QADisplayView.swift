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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Answer")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
