import SwiftUI

/// The main screen: an address bar, the web view, navigation controls, and a
/// "Scan media" button that opens the selection sheet.
struct BrowserView: View {
    @StateObject private var model = WebViewModel()
    @State private var address = ""
    @State private var scanned: [MediaItem] = []
    @State private var showSelection = false
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            WebViewContainer(model: model)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onChange(of: model.urlString) { _, newValue in address = newValue }
        .sheet(isPresented: $showSelection) {
            MediaSelectionView(items: scanned, webModel: model)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("Enter a URL or search", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { model.load(address) }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if model.isLoading {
                ProgressView()
            } else {
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)

            Spacer()

            Button(action: scan) {
                if isScanning {
                    ProgressView()
                } else {
                    Label("Scan media", systemImage: "square.and.arrow.down.on.square")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning)
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func scan() {
        Task {
            isScanning = true
            scanned = await model.scanMedia()
            isScanning = false
            showSelection = true
        }
    }
}
