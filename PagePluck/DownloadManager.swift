import Foundation
import Photos

enum DownloadDestination: Hashable {
    case photos
    case files
}

enum DownloadError: Error {
    case badResponse
    case permissionDenied
    case saveFailed
}

/// Downloads a media file (carrying the user's session cookies) and saves it to
/// either a Photos album or a folder in the Files app.
actor DownloadManager {

    func download(_ item: MediaItem,
                  to destination: DownloadDestination,
                  folderName: String,
                  referer: URL?) async throws {
        var request = URLRequest(url: item.url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.badResponse
        }

        // Stage the file with a sensible extension so Photos/Files recognise it.
        let ext = fileExtension(item: item, response: http)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: tempURL, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        switch destination {
        case .photos:
            try await saveToPhotos(staged, kind: item.kind, albumName: folderName)
        case .files:
            try saveToFiles(staged, fileName: fileName(for: item, ext: ext), folderName: folderName)
        }
    }

    // MARK: - Photos

    private func saveToPhotos(_ fileURL: URL, kind: MediaKind, albumName: String) async throws {
        let status = await requestAddPermission()
        guard status == .authorized || status == .limited else { throw DownloadError.permissionDenied }

        let album = try await fetchOrCreateAlbum(named: albumName)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: kind == .video ? .video : .photo, fileURL: fileURL, options: nil)
                if let placeholder = creation.placeholderForCreatedAsset,
                   let albumChange = PHAssetCollectionChangeRequest(for: album) {
                    albumChange.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? DownloadError.saveFailed) }
            }
        }
    }

    private func requestAddPermission() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }

    private func fetchOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        if let existing = findAlbum(named: name) { return existing }

        var placeholder: PHObjectPlaceholder?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholder = request.placeholderForCreatedAssetCollection
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? DownloadError.saveFailed) }
            }
        }

        guard let id = placeholder?.localIdentifier,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil).firstObject else {
            throw DownloadError.saveFailed
        }
        return album
    }

    private func findAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options).firstObject
    }

    // MARK: - Files

    private func saveToFiles(_ fileURL: URL, fileName: String, folderName: String) throws {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = docs.appendingPathComponent(sanitize(folderName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = uniqueURL(folder.appendingPathComponent(fileName))
        try FileManager.default.copyItem(at: fileURL, to: destination)
    }

    // MARK: - Naming helpers

    private func fileExtension(item: MediaItem, response: HTTPURLResponse) -> String {
        let pathExt = item.url.pathExtension.lowercased()
        if !pathExt.isEmpty, pathExt.count <= 4 { return pathExt }
        switch response.mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/avif": return "avif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return item.kind == .video ? "mp4" : "jpg"
        }
    }

    private func fileName(for item: MediaItem, ext: String) -> String {
        var base = (item.url.deletingPathExtension().lastPathComponent)
        base = sanitize(base)
        if base.isEmpty { base = "media-\(Int(Date().timeIntervalSince1970))" }
        return "\(base).\(ext)"
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
