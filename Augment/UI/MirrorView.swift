@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A live, mirrored front-camera preview in the notch — check your hair
/// before the call (the Hand Mirror idea). The camera runs only while the
/// Mirror tab is on screen.
struct MirrorView: View {
    @ObservedObject private var camera = CameraMirror.shared

    var body: some View {
        ZStack {
            switch camera.state {
            case .running:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(4)
            case .denied:
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 20))
                    Text(Localizer.string("mirror.denied")).font(.system(size: 11)).multilineTextAlignment(.center)
                    Button(Localizer.string("perm.open_settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                    .controlSize(.small)
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding()
            case .unavailable:
                Label(Localizer.string("mirror.no_camera"), systemImage: "video.slash")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            case .idle:
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

@MainActor
final class CameraMirror: ObservableObject {
    static let shared = CameraMirror()

    enum State { case idle, running, denied, unavailable }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.augment.mirror")
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in granted ? CameraMirror.shared.run() : (CameraMirror.shared.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
        if state == .running { state = .idle }
    }

    private func run() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                state = .unavailable
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        let session = self.session
        queue.async {
            session.startRunning()
            Task { @MainActor in CameraMirror.shared.state = .running }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
