import AVFoundation
import SwiftUI
import UIKit

/// Camera sheet that returns the first vigil://pair code it sees. Nothing is recorded or stored.
struct QRScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    Text("Allow camera access in Settings → Vigil to scan the pairing code, or use a PIN instead.")
                        .multilineTextAlignment(.center).padding()
                } else {
                    QRCamera { code in
                        if code.hasPrefix("vigil://pair") { onCode(code) }
                    }
                    .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 240, height: 240)
                }
            }
            .navigationTitle("Scan the code on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
            default: denied = true
            }
        }
    }
}

private struct QRCamera: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return view }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return view }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) { coordinator.session?.stopRunning() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code.hasPrefix("vigil://pair") else { return }
            done = true
            session?.stopRunning()
            onCode(code)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
