//
//  EULAView.swift
//  Screens
//
//  The Terms of Use (App Review Guideline 1.2), in the onboarding's look: the
//  same water gradient and glow, mono eyebrow, serif title, italic body,
//  progress dots and opacity transition. One section per page
//  (TermsContent). Two modes:
//   • Gate (onAccept != nil) — before anything else on a fresh install, after
//     an Erase, and whenever the terms version goes up. Unlike onboarding
//     there is no tap-anywhere: each page has its own explicit button, and
//     the last one is the Accept. "‹" goes back; pages already agreed stay
//     agreed. Nothing is saved until the final Accept (the caller records
//     it), so quitting part way starts again at page 1.
//   • Read-only (onAccept == nil) — from Settings. The same pages with Next /
//     Done and no agreement, plus the version and date the user accepted.
//

import SwiftUI

/// Paging and agreement state, kept out of the view so it can be tested.
struct TermsPager: Equatable {

    enum Mode: Equatable { case gate, readOnly }

    /// What the page's one button does.
    enum Primary: Equatable {
        case agree(String)   // gate: this page not yet agreed (the last page's is the Accept)
        case proceed         // gate: agreed earlier, the user came back
        case next            // read-only
        case done            // read-only, last page
    }

    enum Outcome: Equatable { case stay, accepted, dismissed }

    let mode: Mode
    let pages: [TermsPage]
    private(set) var index = 0
    private(set) var agreed: Set<Int> = []
    /// Set once the Accept has fired; later taps do nothing.
    private(set) var accepted = false

    init(mode: Mode, pages: [TermsPage] = TermsContent.pages) {
        self.mode = mode
        self.pages = pages
    }

    var page: TermsPage { pages[index] }
    var isLast: Bool { index == pages.count - 1 }
    var canGoBack: Bool { index > 0 }
    var isAgreed: Bool { agreed.contains(index) }

    var primary: Primary {
        switch mode {
        case .readOnly:
            return isLast ? .done : .next
        case .gate:
            return isAgreed && !isLast ? .proceed : .agree(page.agreeLabel)
        }
    }

    mutating func tapPrimary() -> Outcome {
        switch mode {
        case .readOnly:
            if isLast { return .dismissed }
            index += 1
            return .stay
        case .gate:
            guard !accepted else { return .stay }
            agreed.insert(index)
            guard isLast else {
                index += 1
                return .stay
            }
            guard agreed.count == pages.count else { return .stay }
            accepted = true
            return .accepted
        }
    }

    mutating func back() {
        if index > 0 { index -= 1 }
    }
}

struct EULAView: View {

    /// Gate mode when non-nil: the last page's Accept is the only way forward.
    /// Read-only (Settings) when nil.
    let onAccept: (() -> Void)?
    /// Read-only mode: the saved acceptance, shown as version + date.
    let acceptedRecord: TermsAcceptanceRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var pager: TermsPager

    init(onAccept: (() -> Void)? = nil, acceptedRecord: TermsAcceptanceRecord? = nil) {
        self.onAccept = onAccept
        self.acceptedRecord = acceptedRecord
        _pager = State(initialValue: TermsPager(mode: onAccept == nil ? .readOnly : .gate))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyss, Stillwater.Palette.abyssDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Stillwater.Palette.biolume.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.28), startRadius: 4, endRadius: 340
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    pageContent
                        .padding(.horizontal, 34)
                        .padding(.top, 28)
                        .padding(.bottom, 24)
                }
                progressDots
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                primaryButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar

    /// "‹" goes back a page; in read-only mode on the first page it closes.
    private var showsBack: Bool { pager.canGoBack || pager.mode == .readOnly }

    private var topBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Text("‹")
                        .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsBack ? 1 : 0)
                .disabled(!showsBack)
                .accessibilityLabel(pager.canGoBack ? "Back" : "Close")
                Spacer()
                Text("TERMS OF USE")
                    .stillwaterMono(10, trackingEm: 0.38, color: Stillwater.Palette.mistDim)
                Spacer()
                Color.clear.frame(width: 32, height: 32)
            }
            if pager.mode == .readOnly, let acceptedRecord {
                Text("you accepted version \(acceptedRecord.version) on \(acceptedRecord.acceptedAt.formatted(date: .abbreviated, time: .omitted))")
                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Page

    private var eyebrow: String {
        let position = "TERMS · \(pager.index + 1) OF \(pager.pages.count)"
        return pager.mode == .gate && pager.isAgreed ? position + " · AGREED" : position
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(eyebrow)
                .stillwaterMono(10, trackingEm: 0.38, color: Stillwater.Palette.mistDim)
            Text(pager.page.title)
                .font(Stillwater.Serif.regular(30))
                .foregroundStyle(Stillwater.Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(pager.page.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(Stillwater.Serif.italic(17))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pager.isLast {
                Text("\(TermsContent.signature) · TERMS VERSION \(TermsVersion.current)")
                    .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(pager.index)   // fresh transition per page
        .transition(.opacity)
    }

    // MARK: - Progress + button

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pager.pages.count, id: \.self) { i in
                Capsule()
                    .fill(i == pager.index ? Stillwater.Palette.biolume : Stillwater.Palette.mist.opacity(0.25))
                    .frame(width: i == pager.index ? 16 : 6, height: 6)
                    .animation(Stillwater.Motion.water(0.4), value: pager.index)
            }
        }
    }

    private var primaryLabel: String {
        switch pager.primary {
        case .agree(let label): return label
        case .proceed: return "Continue"
        case .next: return "Next"
        case .done: return "Done"
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        Button(action: tapPrimary) {
            if pager.mode == .gate {
                Text(primaryLabel)
                    .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Stillwater.Palette.biolume))
                    .contentShape(Rectangle())
            } else {
                Text(primaryLabel)
                    .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.biolume)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.5), lineWidth: 1))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Flow

    private func tapPrimary() {
        var next = pager
        let outcome = next.tapPrimary()
        withAnimation(Stillwater.Motion.water(0.5)) { pager = next }
        switch outcome {
        case .stay: break
        case .accepted: onAccept?()
        case .dismissed: dismiss()
        }
    }

    private func back() {
        guard pager.canGoBack else {
            if pager.mode == .readOnly { dismiss() }
            return
        }
        withAnimation(Stillwater.Motion.water(0.5)) { pager.back() }
    }
}

#Preview("Stillwater — Terms gate") {
    EULAView(onAccept: {})
}

#Preview("Stillwater — Terms read-only") {
    EULAView(acceptedRecord: TermsAcceptanceRecord(version: TermsVersion.current, acceptedAt: Date()))
}
