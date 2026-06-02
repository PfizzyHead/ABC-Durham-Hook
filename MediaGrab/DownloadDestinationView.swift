import SwiftUI

/// Lets you choose, per batch, whether to save into a named Photos album or a
/// named Files folder, then runs the downloads with live progress.
struct DownloadDestinationView: View {
    let items: [MediaItem]
    let referer: URL?
    let webModel: WebViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var destination: DownloadDestination = .photos
    @State private var folderName = ""
    @State private var isDownloading = false
    @State private var completed = 0
    @State private var failed = 0
    @State private var finished = false

    private var trimmedName: String { folderName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var progress: Double {
        items.isEmpty ? 0 : Double(completed + failed) / Double(items.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Save to") {
                    Picker("Destination", selection: $destination) {
                        Label("Photos album", systemImage: "photo.on.rectangle").tag(DownloadDestination.photos)
                        Label("Files folder", systemImage: "folder").tag(DownloadDestination.files)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isDownloading)

                    TextField(destination == .photos ? "Album name" : "Folder name", text: $folderName)
                        .autocorrectionDisabled()
                        .disabled(isDownloading)
                }

                Section {
                    Text(destination == .photos
                         ? "Creates (or reuses) an album named “\(trimmedName.isEmpty ? "…" : trimmedName)” in the Photos app."
                         : "Saves into On My iPhone › Media Grab › \(trimmedName.isEmpty ? "…" : trimmedName) in the Files app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isDownloading || finished {
                    Section {
                        ProgressView(value: progress)
                        HStack {
                            Text("\(completed) saved")
                            if failed > 0 { Text("· \(failed) failed").foregroundStyle(.red) }
                            Spacer()
                            Text("\(completed + failed)/\(items.count)").foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("Download \(items.count) item\(items.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { dismiss() }
                        .disabled(isDownloading)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: start)
                        .disabled(isDownloading || finished || trimmedName.isEmpty)
                }
            }
        }
    }

    private func start() {
        isDownloading = true
        completed = 0
        failed = 0
        Task {
            await webModel.syncCookies()
            let manager = DownloadManager()
            for item in items {
                do {
                    try await manager.download(item, to: destination, folderName: trimmedName, referer: referer)
                    completed += 1
                } catch {
                    failed += 1
                }
            }
            isDownloading = false
            finished = true
        }
    }
}
