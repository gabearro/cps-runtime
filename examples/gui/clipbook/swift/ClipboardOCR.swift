#if os(macOS)
import Foundation
@preconcurrency import Vision
import AppKit

final class ClipboardOCR {
    static func recognizeText(inImageAt path: String, completion: @escaping (String) -> Void) {
        guard let image = NSImage(contentsOfFile: path),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            completion("")
            return
        }
        let request = VNRecognizeTextRequest { request, _ in
            let lines = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            completion(lines.joined(separator: "\n"))
        }
        request.recognitionLevel = .accurate
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        }
    }
}
#endif
