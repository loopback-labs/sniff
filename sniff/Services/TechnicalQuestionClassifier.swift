//
//  TechnicalQuestionClassifier.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import CoreML

final class TechnicalQuestionClassifier {
    private let model: MLModel?
    private let inputKey: String
    private let labelKey: String
    private let probabilityKey: String
    private let positiveLabels: Set<String>
    private let threshold: Double

    init(
        modelName: String = "TechnicalQuestionClassifier",
        bundle: Bundle = .main,
        inputKey: String = "text",
        labelKey: String = "label",
        probabilityKey: String = "labelProbability",
        positiveLabels: Set<String> = ["technical", "tech", "answer", "yes", "true"],
        threshold: Double = 0.55
    ) {
        self.inputKey = inputKey
        self.labelKey = labelKey
        self.probabilityKey = probabilityKey
        self.positiveLabels = Set(positiveLabels.map { $0.lowercased() })
        self.threshold = threshold
        self.model = TechnicalQuestionClassifier.loadModel(named: modelName, bundle: bundle)
    }

    var isModelAvailable: Bool {
        return model != nil
    }

    func isTechnicalQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model = model else { return false }

        let provider = try? MLDictionaryFeatureProvider(dictionary: [inputKey: trimmed])
        guard let input = provider, let output = try? model.prediction(from: input) else {
            return false
        }

        if let label = output.featureValue(for: labelKey)?.stringValue.lowercased(),
           positiveLabels.contains(label) {
            return true
        }

        if let probabilities = output.featureValue(for: probabilityKey)?.dictionaryValue as? [String: NSNumber] {
            if let best = probabilities.max(by: { $0.value.doubleValue < $1.value.doubleValue }) {
                if positiveLabels.contains(best.key.lowercased()) {
                    return true
                }
            }

            for (label, score) in probabilities {
                if positiveLabels.contains(label.lowercased()), score.doubleValue >= threshold {
                    return true
                }
            }
        }

        return false
    }

    private static func loadModel(named name: String, bundle: Bundle) -> MLModel? {
        if let compiledURL = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return try? MLModel(contentsOf: compiledURL)
        }
        if let rawURL = bundle.url(forResource: name, withExtension: "mlmodel") {
            return try? MLModel(contentsOf: rawURL)
        }
        return nil
    }
}
