//
//  PairingView.swift
//  Screens
//
//  STILLWATER · Screen 03 — "Connect" (Pairing).
//
//  VISUAL-ONLY at this stage: pixel-faithful to the Stillwater mockup, built on
//  the Stillwater token foundation, with STATIC placeholder data and NO security
//  calls. The two real flows this screen fronts — in-person QR (proximity ->
//  enroll verified) and remote 4-word SAS (invite + sealed echo -> enroll
//  unverified -> markVerified) — are wired in the later security-finish pass.
//  Nothing here imports or touches EnrollmentService, invites, or the session
//  layer; the Confirm button is inert.
//
//  "Pairing is two hands cupping the same water. No server ever sees it happen.
//   The key is born and dies on these two phones."
//

import SwiftUI

struct PairingView: View {

    /// Placeholder SAS phrase (the real one is derived from both identity keys
    /// during the remote flow). Static here so the screen renders on its own.
    private let words = ["ember", "laurel", "ninth", "tide"]

    var body: some View {
        ZStack {
            // The pool — a radial well of light near the top, sinking to abyss.
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
                    .padding(.top, 34)

                orDivider
                    .padding(.top, 26)

                sasBlock
                    .padding(.top, 4)

                Spacer(minLength: 20)

                confirmButton
                reassurance
                    .padding(.top, 18)
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .background(Stillwater.Palette.abyss)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Header
    // ─────────────────────────────────────────────────────────────
    private var header: some View {
        VStack(spacing: 8) {
            Text("Connect")
                .stillwaterSerif(30, color: Stillwater.Palette.foam)
            Text("add someone to your circle")
                .stillwaterMono(9, trackingEm: 0.28, color: Stillwater.Palette.mistDim)
        }
        .frame(maxWidth: .infinity)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: QR — in person
    // ─────────────────────────────────────────────────────────────
    private var qrBlock: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Stillwater.Palette.foam)
                .frame(width: 212, height: 212)
                .overlay(QRGlyph().padding(22))
                .shadow(color: Stillwater.Palette.biolume.opacity(0.14), radius: 15)

            Text("scan in person · your key, drawn fresh")
                .stillwaterMono(8.5, trackingEm: 0.24)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: OR divider
    // ─────────────────────────────────────────────────────────────
    private var orDivider: some View {
        HStack(spacing: 12) {
            hairline
            Text("or")
                .stillwaterMono(8.5, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
            hairline
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Stillwater.Palette.biolume.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: SAS — far apart, the four words
    // ─────────────────────────────────────────────────────────────
    private var sasBlock: some View {
        VStack(spacing: 12) {
            Text("far apart? read these aloud to each other")
                .stillwaterMono(8.5, trackingEm: 0.22)
                .padding(.top, 14)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(words, id: \.self) { word in
                    Text(word)
                        .stillwaterSerif(21, color: Stillwater.Palette.foam)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Stillwater.Palette.shallow)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.14))
                                )
                        )
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Confirm (inert — wired in the security pass)
    // ─────────────────────────────────────────────────────────────
    private var confirmButton: some View {
        Text("Confirm connection")
            .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(Stillwater.Palette.biolume)
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
}

// ─────────────────────────────────────────────────────────────
// MARK: - QR placeholder glyph
// ─────────────────────────────────────────────────────────────
//
// A deterministic block pattern that READS as a QR at a glance — the three
// finder squares plus a stable pseudo-random field. NOT a scannable code (the
// real payload is rendered during the wired flow); it exists so the screen looks
// right. Drawn in abyss on the foam tile, matching the mockup.
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

    /// Three finder squares in the corners + a deterministic field between them.
    private func fill(_ r: Int, _ c: Int) -> Bool {
        if finder(r, c) { return true }
        if r < 8 && c < 8 { return false }              // clear the TL finder zone
        if r < 8 && c >= n - 8 { return false }         // TR
        if r >= n - 8 && c < 8 { return false }         // BL
        // stable pseudo-random field (no RNG — deterministic across renders)
        return ((r * 73 + c * 31 + r * c) % 5) == 0 || ((r + c) % 3 == 0 && (r * c) % 2 == 0)
    }

    /// A 7×7 finder square (filled border + filled 3×3 center) at a corner.
    private func finder(_ r: Int, _ c: Int) -> Bool {
        func square(_ or_: Int, _ oc: Int) -> Bool {
            let rr = r - or_, cc = c - oc
            guard (0..<7).contains(rr), (0..<7).contains(cc) else { return false }
            if rr == 0 || rr == 6 || cc == 0 || cc == 6 { return true }   // outer ring
            if (2...4).contains(rr) && (2...4).contains(cc) { return true } // inner block
            return false
        }
        return square(0, 0) || square(0, n - 7) || square(n - 7, 0)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────
#Preview("Stillwater — Pairing") {
    PairingView()
}
