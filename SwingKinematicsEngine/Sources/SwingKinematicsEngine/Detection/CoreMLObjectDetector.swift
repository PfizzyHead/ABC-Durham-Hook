// CoreMLObjectDetector.swift
//
// Concrete `SwingObjectDetector` backed by a CoreML model (e.g. a YOLOv8-nano
// exported to `.mlmodelc`) driven through Vision. Compiled only where Vision and
// CoreML are available; on other platforms the type is simply absent and the
// pipeline falls back to an injected detector.

#if canImport(Vision) && canImport(CoreML)
import Foundation
import Vision
import CoreML
import simd

/// Wraps a Vision object-detection request around a CoreML model and maps its
/// `VNRecognizedObjectObservation`s into the engine's `Detection` type.
public final class CoreMLObjectDetector: SwingObjectDetector, @unchecked Sendable {

    private let model: VNCoreMLModel
    private let confidenceThreshold: Double

    /// Maps the model's class label strings onto the engine's vocabulary. Lets
    /// the same code consume models whose label strings differ from ours.
    private let labelMap: [String: SwingObjectLabel]

    /// - Parameters:
    ///   - model: a compiled CoreML detection model.
    ///   - confidenceThreshold: drop detections below this confidence (0...1).
    ///   - labelMap: optional override mapping model labels -> `SwingObjectLabel`.
    ///               Defaults to the identity mapping over the raw values.
    public init(
        model: MLModel,
        confidenceThreshold: Double = 0.25,
        labelMap: [String: SwingObjectLabel]? = nil
    ) throws {
        self.model = try VNCoreMLModel(for: model)
        self.confidenceThreshold = confidenceThreshold
        self.labelMap = labelMap ?? Dictionary(
            uniqueKeysWithValues: SwingObjectLabel.allCases.map { ($0.rawValue, $0) }
        )
    }

    public func detect(in frame: VideoFrame) async throws -> [Detection] {
        guard let pixelBuffer = frame.pixelBuffer else { return [] }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            return []
        }

        return observations.compactMap { observation -> Detection? in
            guard let top = observation.labels.first,
                  let label = labelMap[top.identifier],
                  Double(top.confidence) >= confidenceThreshold else {
                return nil
            }

            // Vision boundingBox is normalized, bottom-left origin.
            let bb = observation.boundingBox
            let box = BoundingBox.fromVisionNormalized(
                x: Double(bb.origin.x),
                y: Double(bb.origin.y),
                width: Double(bb.size.width),
                height: Double(bb.size.height),
                imageSize: frame.size
            )
            return Detection(label: label, confidence: Double(top.confidence), box: box)
        }
    }
}
#endif
