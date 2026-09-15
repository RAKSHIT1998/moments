import Foundation
import Vision
import UIKit

/// On-device text recognition. Returns text in reading order plus a mean confidence.
struct OCRService: Sendable {
    struct Result: Sendable {
        var text: String
        var confidence: Double
        var lineCount: Int
    }

    func recognize(imageData: Data) async throws -> Result {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { throw IntelligenceError.nothingToAnalyze }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: cgImage)
        // Sort top-to-bottom, then left-to-right (Vision's origin is bottom-left).
        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y, by = b.boundingBox.origin.y
            if abs(ay - by) > 0.012 { return ay > by }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }
        var lines: [String] = []
        var confidences: [Double] = []
        for obs in sorted {
            guard let candidate = obs.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            confidences.append(Double(candidate.confidence))
        }
        let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return Result(text: lines.joined(separator: "\n"), confidence: mean, lineCount: lines.count)
    }
}
