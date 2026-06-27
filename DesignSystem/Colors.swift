//
//  Colors.swift
//  DesignSystem
//
//  Mirrors DESIGN_TOKENS_Beacon.txt §1.
//
//  Dark is the source of truth (DESIGN_TOKENS §9). Light values are derived
//  for parity; both ship as DYNAMIC colors that follow the system trait, so
//  the app can be locked to dark at the App level or honor system mode later
//  without touching token call-sites.
//
//  THE QUIET RULE (DESIGN_TOKENS §0). Success is silent. `Color.statusHealthy`
//  is defined in full color for receipts and non-quiet themes, but UI driven
//  by delivery state should reach for `DeliveryColor.text(for:)` rather than
//  the raw token. That helper renders `.delivered`, `.sent`, and
//  `.findingPath` as MUTED neutral by default — color is earned only by
//  states that need attention.
//

import SwiftUI
import UIKit

// MARK: - Hex helpers (file-private)

private extension UIColor {
    /// Initialize from a 24-bit RGB hex literal (e.g. 0x0F1413).
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

/// Build a color that follows the system light/dark trait.
private func dyn(dark: UInt32, light: UInt32, alpha: CGFloat = 1.0) -> Color {
    Color(uiColor: UIColor { trait in
        let hex = trait.userInterfaceStyle == .dark ? dark : light
        return UIColor(hex: hex, alpha: alpha)
    })
}

/// Build a color from white/black overlays at differing alphas in each mode —
/// used by hairlines and rings, which are translucent in both modes.
private func dynOverlay(darkWhite: CGFloat, lightBlack: CGFloat) -> Color {
    Color(uiColor: UIColor { trait in
        if trait.userInterfaceStyle == .dark {
            return UIColor(white: 1, alpha: darkWhite)
        } else {
            return UIColor(white: 0, alpha: lightBlack)
        }
    })
}

// MARK: - Tokens (§1)

extension Color {

    // SURFACES
    static let bgApp        = dyn(dark: 0x0F1413, light: 0xF4F7F6)
    static let bgSurface    = dyn(dark: 0x131817, light: 0xFFFFFF)
    static let bgElevated   = dyn(dark: 0x16221E, light: 0xFFFFFF)
    static let composerBg   = dyn(dark: 0x1A201E, light: 0xFFFFFF)
    static let hairline     = dynOverlay(darkWhite: 0.06, lightBlack: 0.08)
    static let ring         = dynOverlay(darkWhite: 0.04, lightBlack: 0.05)

    // BUBBLES
    static let bubbleInBg     = dyn(dark: 0x1E2422, light: 0xECF1EF)
    static let bubbleInText   = dyn(dark: 0xE4EAE8, light: 0x1C2421)
    static let bubbleOutBg    = dyn(dark: 0x2A322F, light: 0xDCEFE7)
    static let bubbleOutText  = dyn(dark: 0xEAF0EE, light: 0x123A2E)

    // TEXT
    static let textPrimary       = dyn(dark: 0xF2F5F4, light: 0x1C2421)
    static let textSecondary     = dyn(dark: 0x9AA5A0, light: 0x5D6B66)
    static let textTertiary      = dyn(dark: 0x6E7975, light: 0x8A938F)
    static let composerPlaceholder = dyn(dark: 0x5E6967, light: 0x8A938F)

    // BRAND
    static let brand        = dyn(dark: 0x2D8B6F, light: 0x1F6E57)
    static let avatarText   = dyn(dark: 0xEAF5F0, light: 0xEAF5F0)

    // STATUS — semantic. Used by delivery state, presence, signal bars.
    //
    // NOTE: per the Quiet Rule, UI keyed on delivery state should route
    // through `DeliveryColor.text(for:)` instead of reading these directly.
    // Raw tokens remain available for receipts, the live-transit widget, and
    // any non-quiet themes that earn full color.
    static let statusHealthy   = dyn(dark: 0x45C496, light: 0x1D9E75)
    static let statusRelay     = dyn(dark: 0xE0A23B, light: 0xB57A12)
    static let statusRelayFill = dyn(dark: 0xE0A23B, light: 0xE0A23B)
    static let statusError     = dyn(dark: 0xE5594E, light: 0xC0392E)
    static let statusNeutral   = dyn(dark: 0x6E7975, light: 0x8A938F)
}

// MARK: - Avatar gradient

extension Gradient {
    /// The avatar gradient stops (DESIGN_TOKENS §1). Stops never change; only
    /// the hue rotates per-peer (deterministic from public key — see
    /// `Peer.avatarHue`). This is the brand-teal "you" gradient; peer avatars
    /// take this same treatment with a hue rotation applied.
    static let avatarBrand = Gradient(colors: [
        Color(uiColor: UIColor(hex: 0x39A883)),
        Color(uiColor: UIColor(hex: 0x1D5645)),
    ])
}

extension LinearGradient {
    /// The 140° avatar gradient direction (DESIGN_TOKENS §1). SwiftUI uses
    /// unit-square coordinates rather than CSS-style angles; topLeading →
    /// bottomTrailing is the closest match to a 140° line.
    static let avatarBrand = LinearGradient(
        gradient: .avatarBrand,
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )
}

// MARK: - The Quiet Rule

/// Quiet-Rule routing for delivery states (DESIGN_TOKENS §0).
///
/// Success is silent: `.delivered`, `.sent`, and `.findingPath` resolve to
/// the neutral status color even though the underlying token is "healthy."
/// Color is reserved for states that need attention — amber for queue/relay,
/// red for failure.
///
/// Receipts, the live-transit widget, and other "lean-in" surfaces may
/// bypass this and reach for raw tokens; everything else should go through
/// here so the Quiet Rule stays enforced in one place.
enum DeliveryColor {

    /// The text color a delivery-state chip should render in by default.
    static func text(for state: MessageDeliveryState) -> Color {
        switch state {
        case .delivered, .sent, .findingPath:
            return .statusNeutral            // muted by default (Quiet Rule)
        case .waitingForRange, .relayed:
            return .statusRelay              // amber — mesh did/needs work
        case .notDelivered:
            return .statusError              // red — action required
        }
    }
}
