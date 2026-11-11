import Foundation
import Prism
import Vision

/// Reads the words in the graph's pictures — a screenshot's, a receipt's,
/// a whiteboard's — and tells them to the engine, which finds pages by
/// them as by their own words. The engine says which pictures are still
/// to be read, and keeps what each said; all that is done here is the
/// reading, which is the device's (Vision's) to do.
///
/// A few at a time, in the background, at no one's expense: whenever the
/// graph has changed, until none is left. A picture is read once.
enum PictureWords {
    /// The words Vision reads in a picture, a line to a line. Nothing,
    /// for a picture without any, or a file that is no picture.
    static func read(_ url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(url: url, options: [:]).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Reads every picture the engine has yet to hear of. Answers how many it read.
    static func readAll(engine: PrismEngine, root: URL) async -> Int {
        var count = 0
        while !Task.isCancelled, let unread = try? engine.picturesUnread(limit: 8), !unread.isEmpty {
            for asset in unread {
                if Task.isCancelled { return count }
                let url = root.appendingPathComponent(asset)
                // Not there yet — still on its way in: left for the next time round.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try? engine.setPictureWords(asset: asset, words: read(url))
                count += 1
                await Task.yield()
            }
            // Only files that are not there are left: nothing more to do for now.
            if unread.allSatisfy({ !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) { break }
        }
        return count
    }
}
