import Foundation

enum MediaKind: String, Codable {
    case image
    case video
}

/// A single image or video discovered on a page.
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
    var posterURL: URL?     // thumbnail / poster frame, mainly for videos
    var width: Int?
    var height: Int?

    /// A reasonable file/display name derived from the URL.
    var displayName: String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host ?? "media" }
        return last
    }
}

extension MediaItem {
    /// Builds an item from the JSON dictionary produced by the page scanner.
    init?(dict: [String: Any]) {
        guard let urlString = dict["url"] as? String,
              let url = URL(string: urlString) else { return nil }
        self.url = url
        let kindString = (dict["kind"] as? String) ?? "image"
        self.kind = MediaKind(rawValue: kindString) ?? .image
        if let poster = dict["poster"] as? String { self.posterURL = URL(string: poster) }
        self.width = (dict["width"] as? NSNumber)?.intValue
        self.height = (dict["height"] as? NSNumber)?.intValue
    }
}
