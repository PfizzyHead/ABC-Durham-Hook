import Combine
import Foundation

enum CaptureSystemState: Equatable {
    case idle
    case listening
    case recording
    case exporting
}

@MainActor
final class ImpactCaptureBridge: ObservableObject {
    @Published var currentState: CaptureSystemState = .idle
    @Published var debugLogs: [String] = []
    @Published var lastExportedVideoURL: URL?
    @Published var attackRatio: Float = 6.0 {
        didSet { applyThresholds() }
    }
    @Published var brightnessRatio: Float = 0.45 {
        didSet { applyThresholds() }
    }
    @Published var highBandHz: Float = 2_000 {
        didSet { applyThresholds() }
    }

    private let coordinator: ImpactCaptureCoordinator
    private let maxLogCount = 250

    init(coordinator: ImpactCaptureCoordinator = ImpactCaptureCoordinator()) {
        self.coordinator = coordinator
        configureCallbacks()
        applyThresholds()
    }

    func startListening() {
        guard currentState == .idle else {
            appendLog("Start ignored while state is \(currentState.label).")
            return
        }

        appendLog("Requesting camera and microphone permissions.")
        coordinator.requestPermissions { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.currentState = .idle
                    self.appendLog("Permission denied. Camera and microphone are required.")
                    return
                }

                do {
                    self.appendLog("Starting impact capture pipeline.")
                    self.applyThresholds()
                    try self.coordinator.startSession()
                    self.currentState = .listening
                    self.appendLog("Listening for acoustic impact trigger.")
                } catch {
                    self.currentState = .idle
                    self.appendLog("Failed to start capture: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopListening() {
        appendLog("Stopping capture pipeline.")
        coordinator.stopSession()
        currentState = .idle
    }

    private func configureCallbacks() {
        coordinator.onCaptureStateChange = { [weak self] state in
            Task { @MainActor in
                self?.currentState = state
                self?.appendLog("Capture state changed: \(state.label).")
            }
        }

        coordinator.onClipReady = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let url):
                    self?.lastExportedVideoURL = url
                    self?.appendLog("Exported swing clip: \(url.lastPathComponent)")
                case .failure(let error):
                    self?.appendLog("Export failed: \(error.localizedDescription)")
                }
            }
        }

        coordinator.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.appendLog("Session status: \(status.debugDescription)")
            }
        }
    }

    private func applyThresholds() {
        coordinator.updateTriggerThresholds(
            attackRatio: attackRatio,
            brightnessRatio: brightnessRatio,
            highBandHz: highBandHz
        )
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        debugLogs.append("[\(timestamp)] \(message)")
        if debugLogs.count > maxLogCount {
            debugLogs.removeFirst(debugLogs.count - maxLogCount)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private extension CaptureSystemState {
    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .listening:
            return "listening"
        case .recording:
            return "recording"
        case .exporting:
            return "exporting"
        }
    }
}

private extension CameraSessionManager.Status {
    var debugDescription: String {
        switch self {
        case .interrupted(let reason):
            if let reason {
                return "interrupted (\(reason))"
            }
            return "interrupted"
        case .interruptionEnded:
            return "interruption ended"
        case .runtimeError(let error):
            return "runtime error: \(error.localizedDescription)"
        case .thermalStateChanged(let state):
            return "thermal state changed: \(state)"
        }
    }
}
