//
//  QRScannerView.swift
//  Screens
//
//  A minimal AVFoundation QR scanner wrapped for SwiftUI (STEP 7d-2). Presents the
//  camera preview and calls `onFound` ONCE with the decoded string the first time
//  a QR resolves. It reads `stringValue` — which is why the pairing QR encodes a
//  base64url STRING (aeronyra://pair/…), not raw bytes: binary payloads don't
//  round-trip through AVFoundation's stringValue.
//
//  CONCURRENCY: the metadata delegate is the Coordinator (a plain NSObject, so it
//  cleanly satisfies the nonisolated AVFoundation requirement — a @MainActor
//  UIViewController can't). Its callback queue is pinned to `.main`, so `onFound`
//  runs on the main actor and can safely drive SwiftUI state.
//
//  Camera permission: requires `NSCameraUsageDescription` in Info.plist, or the
//  app traps on session start. Requests access on appear; on denial the preview
//  stays black (the caller shows a hint + the invite fallback).
//

import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {

    /// Called once, on the main queue, with the first decoded QR string.
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(metadataDelegate: context.coordinator)
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (String) -> Void
        private var delivered = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        // Delivered on the `.main` queue (set on the output below), fired once.
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let string = object.stringValue else { return }
            delivered = true
            onFound(string)
        }
    }
}

final class ScannerViewController: UIViewController {

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private weak var metadataDelegate: AVCaptureMetadataOutputObjectsDelegate?

    init(metadataDelegate: AVCaptureMetadataOutputObjectsDelegate) {
        self.metadataDelegate = metadataDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.startSession() } }
            }
        default:
            break   // denied / restricted — preview stays black; caller hints
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func startSession() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
}
