//
//  Typography.swift
//  DesignSystem
//
//  Mirrors DESIGN_TOKENS_Beacon.txt §2.
//
//  The split between Interface (Geist) and Mono (Geist Mono) is intentional:
//  telemetry — every delivery state, every receipt line, every eyebrow — reads
//  as instrumentation. This file is the ONLY place font choices live. Views
//  reach for token names like `.headerName`, never raw font strings.
//

import SwiftUI

enum Typography {

    // MARK: - Weights

    /// Geist (interface) weights. Maps to bundled PostScript names.
    enum InterfaceWeight {
        case regular    // 400
        case medium     // 500
        case semibold   // 600
        case bold       // 700

        fileprivate var postScriptName: String {
            switch self {
            case .regular:  return "Geist-Regular"
            case .medium:   return "Geist-Medium"
            case .semibold: return "Geist-SemiBold"
            case .bold:     return "Geist-Bold"
            }
        }
    }

    /// Geist Mono (telemetry) weights. Maps to bundled PostScript names.
    enum MonoWeight {
        case regular    // 400
        case medium     // 500
        case semibold   // 600

        fileprivate var postScriptName: String {
            switch self {
            case .regular:  return "GeistMono-Regular"
            case .medium:   return "GeistMono-Medium"
            case .semibold: return "GeistMono-SemiBold"
            }
        }
    }

    // MARK: - Raw builders
    //
    // Use these only when a named token below doesn't fit. Every callsite that
    // reaches for `interface()` or `mono()` directly is a candidate for a new
    // named token.

    /// Geist (interface) — body text, headings, labels.
    static func interface(_ weight: InterfaceWeight, size: CGFloat) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    /// Geist Mono (telemetry) — anything that should read as instrumentation.
    static func mono(_ weight: MonoWeight, size: CGFloat) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    // MARK: - Named tokens (DESIGN_TOKENS §2)

    /// Status-bar time. 14 / 600.
    static let statusBarTime = interface(.semibold, size: 14)

    /// Header name. 15 / 600.
    static let headerName = interface(.semibold, size: 15)

    /// Header presence label. 11.5 / 500.
    static let headerPresence = interface(.medium, size: 11.5)

    /// Message body. 14.5 / 400. Pair with `.beaconMessageBody()` for the
    /// correct 1.34 line-height — a raw `Font` value can't carry line spacing.
    static let messageBody = interface(.regular, size: 14.5)

    /// Delivery-state chip. 11 / 500 MONO.
    static let deliveryChip = mono(.medium, size: 11)

    /// Delivery-state chip when inside a boxed background. 10.5 / 500 MONO.
    static let deliveryChipBoxed = mono(.medium, size: 10.5)

    /// Section eyebrow. 11 / 600 MONO. Pair with `.beaconEyebrow()` to get
    /// uppercase + tracking together.
    static let sectionEyebrow = mono(.semibold, size: 11)

    /// Day divider. 10 / 600 MONO. Pair with `.beaconDayDivider()` for the
    /// correct tracking.
    static let dayDivider = mono(.semibold, size: 10)

    /// Delivery-receipt node label. 10 / 600 MONO.
    static let receiptNodeLabel = mono(.semibold, size: 10)

    /// Delivery-receipt status line. 11 / 500 MONO.
    static let receiptStatus = mono(.medium, size: 11)

    // MARK: - Metrics (tracking & line-height)
    //
    // SwiftUI applies tracking and line-spacing as VIEW modifiers, not as
    // font attributes. The spec gives values in em (font-relative); they
    // translate to points (absolute) at each token's size.

    /// Message body line-spacing: 14.5pt × 1.34 line-height ≈ 5pt extra.
    static let messageBodyLineSpacing: CGFloat = 5

    /// Eyebrow tracking, in points. Spec: .16–.22em at 11pt ≈ 1.8–2.4pt.
    /// Default to the lower end; bump on hero eyebrows.
    static let eyebrowTracking: CGFloat = 1.8

    /// Day-divider tracking, in points. Spec: .08em at 10pt = 0.8pt.
    static let dayDividerTracking: CGFloat = 0.8
}

// MARK: - View helpers
//
// Convenience modifiers that bundle font + tracking + line-spacing into a
// single call site, matching the spec exactly. Use these instead of stacking
// .font(.x).tracking(y).lineSpacing(z) at every callsite.

extension View {
    /// Spec-correct message body: Geist 400 at 14.5pt, 1.34 line-height.
    func beaconMessageBody() -> some View {
        self
            .font(Typography.messageBody)
            .lineSpacing(Typography.messageBodyLineSpacing)
    }

    /// Spec-correct section eyebrow: Geist Mono 600 at 11pt, uppercased,
    /// tracked.
    func beaconEyebrow() -> some View {
        self
            .font(Typography.sectionEyebrow)
            .tracking(Typography.eyebrowTracking)
            .textCase(.uppercase)
    }

    /// Spec-correct day divider: Geist Mono 600 at 10pt, lightly tracked.
    func beaconDayDivider() -> some View {
        self
            .font(Typography.dayDivider)
            .tracking(Typography.dayDividerTracking)
    }
}
