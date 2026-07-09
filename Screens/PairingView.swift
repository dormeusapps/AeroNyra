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
    @State private var qrText: String?          // the ONE fresh-payload string per open
    @State private var qrExpanded = false
    @State private var savedBrightness: CGFloat?
    @State private var inviteString: String?
    @State private var minting = false
    @State private var mintError: String?

    // Redeem-an-invite (7d-3 UI): the pasted/typed string and in-flight flag.
    @State private var inviteInput = ""
    @State private var redeeming = false

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
        .fullScreenCover(isPresented: $qrExpanded) { expandedQRCover }
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
                .onTapGesture {
                    if qrImage != nil { qrExpanded = true }
                }

            Text(qrUnavailable
                 ? "key too large for one code · use an invite below"
                 : "your key, drawn fresh · tap to enlarge for scanning")
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
                    // Share as a URL item, not a String: Mail then renders a
                    // tappable anchor (the custom scheme survives), AirDrop
                    // keeps its open-in-app behavior. String fallback if URL
                    // init refuses — never force-unwrap.
                    Group {
                        if let url = URL(string: invite) {
                            ShareLink(item: url) { pill("share your invite") }
                        } else {
                            ShareLink(item: invite) { pill("share your invite") }
                        }
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

            // Redeem an incoming invite. PasteButton covers the clean copy
            // without the iOS "Allow Paste?" alert; the field is for an invite
            // that arrived hard-wrapped in a plain-text email and needs a
            // hand-repair before redeeming.
            VStack(spacing: 10) {
                Text("got an invite? redeem it here")
                    .stillwaterMono(8.5, trackingEm: 0.22)

                HStack(spacing: 10) {
                    TextField("paste their invite", text: $inviteInput)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Stillwater.Palette.foam)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Stillwater.Palette.biolume.opacity(0.25))
                        )
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        redeemPasted(s)
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }

                Button { redeemPasted(inviteInput) } label: {
                    outlinePill(redeeming ? "redeeming…" : "redeem invite")
                }
                .buttonStyle(.plain)
                .disabled(redeeming || pairing == nil || inviteInput.isEmpty)
            }
            .padding(.top, 14)

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

    /// Redeem a pasted/typed invite. Same presentation pair as handleScan
    /// (pairMessage/pairFailed); RedactLog on failure only, discriminant-label
    /// only — never the invite string, never any bytes of it.
    private func redeemPasted(_ raw: String) {
        guard let pairing, !redeeming else { return }
        redeeming = true
        pairMessage = nil
        pairFailed = nil
        Task {
            do {
                let result = try await pairing.redeemInvite(raw)
                pairMessage = "invite redeemed · \(result.hint) · now confirm the four words"
                inviteInput = ""
            } catch PairingService.PairError.expired {
                pairFailed = "that invite has expired — ask for a fresh one"
                RedactLog.event("invite-paste: FAILED expired", "")
            } catch PairingService.PairError.unrecognized {
                // Covers wrong-link AND transport-damaged: .malformed is
                // unreachable here (a bad payload dies inside Invite(wire:)).
                pairFailed = "couldn't read that invite — check it copied in full"
                RedactLog.event("invite-paste: FAILED unrecognized", "")
            } catch PairingService.PairError.malformed {
                pairFailed = "that invite was damaged — ask for a fresh one"
                RedactLog.event("invite-paste: FAILED malformed", "")
            } catch PairingService.PairError.selfScan {
                pairFailed = "that's your own invite"
                RedactLog.event("invite-paste: FAILED self", "")
            } catch {
                pairFailed = "couldn't redeem — try again"
                RedactLog.event("invite-paste: FAILED downstream", "\(type(of: error))")
            }
            redeeming = false
        }
    }

    // MARK: Expanded QR (scan-size render)
    /// Full-width, pure black-on-white, brightness pinned: the 200 pt themed
    /// tile is a decorative preview at this payload's density. This is the
    /// render the other phone actually reads. The bitmap is 1 px/module and
    /// only ever UPSCALED (nearest-neighbor keeps modules crisp); downscaling
    /// a pre-scaled bitmap decimates modules and kills the scan.
    private var expandedQRCover: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 26) {
                if let qrText,
                   let img = Self.makeQRImage(from: qrText, dark: .black, light: .white) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(24)          // extra quiet zone
                }
                Text("have them scan · tap anywhere to close")
                    .stillwaterMono(9, trackingEm: 0.24, color: .black.opacity(0.55))
            }
        }
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }
        .onDisappear {
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        }
        .onTapGesture { qrExpanded = false }
    }

    private func buildQR() {
        guard qrImage == nil, !qrUnavailable, let pairing else { return }
        do {
            let text = try pairing.makeOurQRString()
            // Growth guard, not a scannability promise: CIFilter's byte-mode
            // ceiling at level L is 2,953 encoded chars (2,190 wire bytes +
            // the 16-char prefix ≈ 2,937). Past this the filter refuses and
            // the tile silently blanks; refuse first with honest copy. Today's
            // ~1,881-byte payload passes — and is still DENSE (version ≈37);
            // this guard does not make it scannable, the expanded render does.
            let approxWireBytes = (text.utf8.count - "aeronyra://pair/".count) * 3 / 4
            guard approxWireBytes <= 2_190 else {
                qrUnavailable = true
                return
            }
            qrText = text
            if let img = Self.makeQRImage(from: text,
                                          dark: UIColor(Stillwater.Palette.abyss),
                                          light: UIColor(Stillwater.Palette.foam)) {
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

    /// Render `text` as a QR at 1 px/module. `L` correction maximizes capacity
    /// for the dense pairing string; returns nil if it overflows one code.
    /// NO pre-scale: the old 12× transform produced a ~2,000 px bitmap that
    /// every on-screen size then DOWNSCALED with nearest-neighbor, decimating
    /// modules. At scale 1 the view layer only ever upscales, which is lossless
    /// for a module grid.
    private static func makeQRImage(from text: String,
                                    dark: UIColor, light: UIColor) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }

        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(color: dark),
            "inputColor1": CIColor(color: light),
        ])
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(colored, from: colored.extent) else { return nil }
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
