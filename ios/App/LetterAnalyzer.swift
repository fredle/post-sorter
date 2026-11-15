import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

enum ExtractionSource {
    case appleIntelligence, patterns, noText

    var message: String {
        switch self {
        case .appleIntelligence:
            return "Read on this iPhone with Apple Intelligence. Check the details before saving."
        case .patterns:
            return "Read on this iPhone. Check the details before saving."
        case .noText:
            return "No text could be read. Fill in the details yourself, or scan again in better light."
        }
    }

    var symbol: String {
        switch self {
        case .appleIntelligence: return "sparkles"
        case .patterns: return "text.viewfinder"
        case .noText: return "exclamationmark.triangle"
        }
    }
}

struct AnalysisResult {
    var images: [UIImage]
    var text: String
    var fields: ExtractedFields
    var source: ExtractionSource
}

/// Turns page images into text and fields, entirely on the phone.
enum LetterAnalyzer {
    static func analyze(images: [UIImage], embeddedText: String?, now: Date = Date()) async -> AnalysisResult {
        let pages = await Task.detached(priority: .userInitiated) {
            images.map { ImageProcessing.normalized($0) }
        }.value

        let text: String
        if let embeddedText, embeddedText.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
            text = embeddedText
        } else {
            text = await Task.detached(priority: .userInitiated) {
                TextRecognizer.recognize(pages)
            }.value
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AnalysisResult(images: pages, text: "", fields: ExtractedFields(needsAction: true), source: .noText)
        }

        let patternFields = PatternExtractor.extract(from: text, now: now)
        if let aiFields = await OnDeviceModel.extract(text: text, now: now) {
            return AnalysisResult(images: pages, text: text, fields: aiFields.filling(from: patternFields), source: .appleIntelligence)
        }
        return AnalysisResult(images: pages, text: text, fields: patternFields, source: .patterns)
    }
}

enum TextRecognizer {
    static func recognize(_ images: [UIImage]) -> String {
        images.map { recognize($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func recognize(_ image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

enum ImageProcessing {
    /// Redraws the image upright and no larger than `maxDimension` pixels on its long side.
    static func normalized(_ image: UIImage, maxDimension: CGFloat = 2400) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

enum FileLoaderError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "That file couldn't be opened. Choose a PDF or a photo."
    }
}

/// Opens an imported PDF or image file as page images (plus any text a PDF already contains).
enum FileLoader {
    static let maxPages = 12

    static func copyToTemporary(_ url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func load(_ url: URL) throws -> (images: [UIImage], text: String?) {
        defer { try? FileManager.default.removeItem(at: url) }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw FileLoaderError.unreadable }
            var images: [UIImage] = []
            var texts: [String] = []
            for index in 0..<min(document.pageCount, maxPages) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 2000 / max(bounds.width, bounds.height, 1)
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                images.append(page.thumbnail(of: size, for: .mediaBox))
                if let string = page.string, !string.isEmpty { texts.append(string) }
            }
            guard !images.isEmpty else { throw FileLoaderError.unreadable }
            return (images, texts.isEmpty ? nil : texts.joined(separator: "\n\n"))
        }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw FileLoaderError.unreadable
        }
        return ([image], nil)
    }
}
