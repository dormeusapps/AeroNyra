//
//  PairingView.swift
//  Screens
//
//  STILLWATER · Screen 03 — "Connect" (Pairing).
//
//  WIRED (7d-1 outbound + 7d-2 scan). The QR encodes OUR real pairing payload as a
//  base64url string (aeronyra://pair/…, so AVFoundation can read it back); the
//  remote path mints a real single-use invite; and "scan their code" opens the
//  camera, decodes their payload, establishes a session (via the coordinator's
//  tie-break) and enrolls them VERIFIED — all through `PairingService`.
//
//  NOT YET WIRED (later sub-steps):
//    • 7d-3 redeem an incoming invite (+ the 7c-2 echo emit)
//    • 7d-4 the 4-word SAS confirm (needs a formed session) → markVerified
//
//  "Pairing is two hands cupping the same water. No server ever sees it happen.
//   The key is born and dies on these two phones."
//

import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct PairingView: View {

    @Environment(PairingService.self) private var pairing: PairingService?
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?
    @State private var qrUnavailable = false
    @State private var inviteString: String?
    @State private var minting = false
    @State private var mintError: String?

    @State private var showScanner = false
    @State private var pairMessage: String?
    @State private var pairFailed: String?

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyssDeep],
                center: .init(x: 0.5, y: 0.30),
                startRadius: 8, endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                qrBlock
                    .padding(.top, 30)

                orDivider
                    .padding(.top, 24)

                inviteBlock
                    .padding(.top, 16)

                Spacer(minLength: 18)

                reassurance
                    .padding(.top, 16)
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .background(Stillwater.Palette.abyss)
        .task { buildQR() }
        .fullScreenCover(isPresented: $showScanner) { scannerCover }
    }

    // MARK: Header
    private var header: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Text("‹").stillwaterSerif(20, color: Stillwater.Palette.mistDim)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            VStack(spacing: 8) {
                Text("Connect")
                    .stillwaterSerif(30, color: Stillwater.Palette.foam)
                Text("add someone to your circle")
                    .stillwaterMono(9, trackingEm: 0.28, color: Stillwater.Palette.mistDim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: QR — in person (show ours + scan theirs)
    private var qrBlock: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Stillwater.Palette.foam)
                .frame(width: 200, height: 200)
                .overlay {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        QRGlyph().padding(20)
                    }
                }
                .shadow(color: Stillwater.Palette.biolume.opacity(0.14), radius: 15)

            Text(qrUnavailable
                 ? "key too large for one code · use an invite below"
                 : "your key, drawn fresh · have them scan it")
                .stillwaterMono(8.5, trackingEm: 0.24)

            Button { openScanner() } label: {
                outlinePill("scan their code")
            }
            .buttonStyle(.plain)
            .disabled(pairing == nil)
            .opacity(pairing == nil ? 0.4 : 1.0)

            if let pairMessage {
                Text(pairMessage)
                    .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.biolume)
            }
            if let pairFailed {
                Text(pairFailed)
                    .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDim)
            }
        }
    }

    // MARK: OR divider
    private var orDivider: some View {
        HStack(spacing: 12) {
            hairline
            Text("or").stillwaterMono(8.5, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
            hairline
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Stillwater.Palette.biolume.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: Invite — far apart (mint + share a single-use link)
    private var inviteBlock: some View {
        VStack(spacing: 12) {
            Text("far apart? send a one-time invite")
                .stillwaterMono(8.5, trackingEm: 0.22)

            if let invite = inviteString {
                VStack(spacing: 10) {
                    ShareLink(item: invite) {
                        pill("share your invite")
                    }
                    .buttonStyle(.plain)

                    Text("expires in 10 min · one use · redeem lands next")
                        .stillwaterMono(7.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)

                    Button { inviteString = nil } label: {
                        Text("make another")
                            .stillwaterMono(8, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: mint) {
                    pill(minting ? "minting…" : "create a one-time invite")
                }
                .buttonStyle(.plain)
                .disabled(minting || pairing == nil)
                .opacity(pairing == nil ? 0.4 : 1.0)
            }

            if let mintError {
                Text(mintError)
                    .stillwaterMono(8, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 26).fill(Stillwater.Palette.biolume))
    }

    private func outlinePill(_ text: String) -> some View {
        Text(text)
            .stillwaterSerif(15, color: Stillwater.Palette.biolume)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 23)
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.4))
            )
    }

    private var reassurance: some View {
        VStack(spacing: 3) {
            Text("no server ever sees this")
            Text("the key is born and dies on these two phones")
        }
        .stillwaterMono(8, trackingEm: 0.2, color: Stillwater.Palette.mistDimmest)
        .multilineTextAlignment(.center)
        .lineSpacing(4)
        .frame(maxWidth: .infinity)
    }

    // MARK: Scanner cover
    private var scannerCover: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            QRScannerView { code in
                showScanner = false
                handleScan(code)
            }
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Stillwater.Palette.biolume.opacity(0.85), lineWidth: 2)
                .frame(width: 236, height: 236)

            VStack {
                HStack {
                    Button { showScanner = false } label: {
                        Text("close")
                            .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.foam)
                    }
                    .padding(20)
                    Spacer()
                }
                Spacer()
                Text("point at their code")
                    .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.foam)
                    .padding(.bottom, 54)
            }
        }
    }

    // MARK: Actions
    private func openScanner() {
        pairMessage = nil
        pairFailed = nil
        showScanner = true
    }

    private func handleScan(_ code: String) {
        Task {
            do {
                if let result = try await pairing?.pairFromScanned(code) {
                    pairMessage = "connected · \(result.hint)"
                }
            } catch PairingService.PairError.selfScan {
                pairFailed = "that's your own code"
            } catch PairingService.PairError.unrecognized {
                pairFailed = "not an AeroNyra code"
            } catch PairingService.PairError.malformed {
                pairFailed = "that code was damaged — try again"
            } catch {
                pairFailed = "couldn't connect — try again"
            }
        }
    }

    private func buildQR() {
        guard qrImage == nil, !qrUnavailable, let pairing else { return }
        do {
            let text = try pairing.makeOurQRString()
            if let img = Self.makeQRImage(from: text) {
                qrImage = img
            } else {
                qrUnavailable = true
            }
        } catch {
            qrUnavailable = true
        }
    }

    private func mint() {
        guard let pairing, !minting else { return }
        minting = true
        mintError = nil
        Task {
            do { inviteString = try await pairing.mintInviteString() }
            catch { mintError = "couldn't mint an invite — try again" }
            minting = false
        }
    }

    /// Render `text` as a QR: abyss modules on a foam ground. `L` correction
    /// maximizes capacity for the dense pairing string; returns nil if it still
    /// overflows one code.
    private static func makeQRImage(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }

        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(color: UIColor(Stillwater.Palette.abyss)),
            "inputColor1": CIColor(color: UIColor(Stillwater.Palette.foam)),
        ])
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - QR placeholder glyph (preview / fallback only)
private struct QRGlyph: View {
    private let n = 21

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(n)
            Canvas { ctx, _ in
                for r in 0..<n {
                    for c in 0..<n {
                        guard fill(r, c) else { continue }
                        let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                          width: cell, height: cell)
                        ctx.fill(Path(rect), with: .color(Stillwater.Palette.abyss))
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func fill(_ r: Int, _ c: Int) -> Bool {
        if finder(r, c) { return true }
        if r < 8 && c < 8 { return false }
        if r < 8 && c >= n - 8 { return false }
        if r >= n - 8 && c < 8 { return false }
        return ((r * 73 + c * 31 + r * c) % 5) == 0 || ((r + c) % 3 == 0 && (r * c) % 2 == 0)
    }

    private func finder(_ r: Int, _ c: Int) -> Bool {
        func square(_ or_: Int, _ oc: Int) -> Bool {
            let rr = r - or_, cc = c - oc
            guard (0..<7).contains(rr), (0..<7).contains(cc) else { return false }
            if rr == 0 || rr == 6 || cc == 0 || cc == 6 { return true }
            if (2...4).contains(rr) && (2...4).contains(cc) { return true }
            return false
        }
        return square(0, 0) || square(0, n - 7) || square(n - 7, 0)
    }
}

// MARK: - Preview
#Preview("Stillwater — Pairing") {
    PairingView()
}
