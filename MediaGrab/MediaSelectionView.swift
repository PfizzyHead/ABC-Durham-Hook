import SwiftUI

/// Grid of everything found on the page. Tap to (de)select, then continue to
/// choose where the chosen items are saved.
struct MediaSelectionView: View {
    let items: [MediaItem]
    let webModel: WebViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<MediaItem.ID> = []
    @State private var showDestination = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(selected.isEmpty ? "Found \(items.count)" : "\(selected.count) selected")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !items.isEmpty {
                            Button(selected.count == items.count ? "Deselect all" : "Select all", action: toggleAll)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { downloadButton }
                .sheet(isPresented: $showDestination) {
                    DownloadDestinationView(
                        items: items.filter { selected.contains($0.id) },
                        referer: webModel.currentURL,
                        webModel: webModel
                    )
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "No media found",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Scroll the page to load more content, then scan again. Some sites load images only as you scroll.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items) { item in
                        MediaThumb(item: item, selected: selected.contains(item.id))
                            .onTapGesture { toggle(item) }
                    }
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if !items.isEmpty {
            Button { showDestination = true } label: {
                Text(selected.isEmpty ? "Select items to download"
                     : "Download \(selected.count) item\(selected.count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .disabled(selected.isEmpty)
        }
    }

    private func toggle(_ item: MediaItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func toggleAll() {
        if selected.count == items.count { selected.removeAll() }
        else { selected = Set(items.map(\.id)) }
    }
}

/// A square thumbnail with a selection check and a video badge.
struct MediaThumb: View {
    let item: MediaItem
    let selected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemGray5)
                .overlay {
                    AsyncImage(url: item.kind == .video ? (item.posterURL ?? item.url) : item.url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: item.kind == .video ? "film" : "photo")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
                .clipped()

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, selected ? Color.accentColor : .white.opacity(0.7))
                .background(selected ? Color.accentColor.opacity(0.0) : .black.opacity(0.25), in: Circle())
                .padding(5)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
        }
    }
}
