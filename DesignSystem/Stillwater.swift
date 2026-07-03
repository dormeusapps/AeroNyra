//
//  Stillwater.swift
//  DesignSystem
//
//  THE STILLWATER DESIGN LANGUAGE — token foundation (screen 0 of the UI track).
//
//  "AeroNyra is still water. Your circle is a small dark pool. A message is a
//   stone skipped across its surface. Presence is bioluminescence: brightness
//   IS state. Light moves; surfaces stay still."
//
//  This file is the single source of truth for Stillwater's palette, type, and
//  motion — everything Home / Conversation / Pairing build on. It is PURE design
//  foundation: no app types, no security, no dependencies beyond SwiftUI. It does
//  NOT touch or reference the pre-Stillwater DesignSystem files (Colors.swift /
//  Typography.swift); everything here lives under the `Stillwater` namespace and
//  defines no `Color(hex:)` / `Font` extensions, so it cannot collide with them.
//
//  THE ONE RULE (locked): state is carried by the BRIGHTNESS of a single accent,
//  never a second hue. A human wrote it -> serif (Newsreader). The mesh said it ->
//  mono whisper (Spline Sans Mono, uppercase, tracked, small). See `Presence`.
//
//  Fonts are registered in Info.plist (UIAppFonts) + Copy Bundle Resources. The
//  PostScript names carry a deliberate quirk baked in below so no caller repeats
//  it: Newsreader has NO hyphen after the family ("Newsreader14pt-Regular"),
//  Spline DOES ("SplineSansMono-Regular"). Faces are requested `fixedSize` so the
//  screens render at the mockup's exact points (pixel-faithful, not Dynamic-Type
//  scaled). Swapping `fixedSize:` -> `size:` later is the one-line accessibility
//  path if we choose to scale.
//

import SwiftUI

enum Stillwater {

    // ─────────────────────────────────────────────────────────────
    // MARK: Palette — one light, many depths
    // ─────────────────────────────────────────────────────────────
    //
    // The six named tokens are the system language. The derived tones below are
    // the graded foam/mist the mockup uses to read depth without a second hue.
    enum Palette {
        // The named six (THE SYSTEM LANGUAGE · Color)
        static let abyss  = c(0x050B0A)   // THE GROUND — deepest background
        static let water  = c(0x0A1514)   // SURFACES — panels
        static let shallow = c(0x12211E)  // RAISED — cards, the SAS word tiles
        static let foam   = c(0xE9F5EF)   // HUMAN TEXT — names, messages
        static let mist   = c(0x8FA8A0)   // WHISPERS — the mesh's mono labels
        /// BIOLUMINESCENCE — the one accent. Themeable in Settings (defaults to the
        /// canonical teal). Read each access so a change recolours the app on the
        /// next render and fully on relaunch. Brightness-as-state is unchanged.
        static var biolume: Color { hex(Accent.currentHex) }

        // Derived tones (depth grading + surfaces the mockup actually renders)
        static let foamDim     = c(0xB9CAC3) // a name reached only over the relay
        static let mistDim     = c(0x5C726B) // dim mono labels; a "gone" name
        static let mistDimmest = c(0x41504B) // timestamps, the deepest whispers
        static let onAccent    = c(0x04110C) // text/glyph on a biolume fill
        static let goneRing    = c(0x2A3A36) // the hollow ring of a dark peer
        static let abyssDeep   = c(0x030706) // deepest gradient stop

        /// Internal hex→Color for the accent presets and the themed `biolume`.
        static func hex(_ h: UInt) -> Color { c(h) }

        /// Hex -> Color without a `Color(hex:)` extension, so nothing in the
        /// project's existing DesignSystem can collide with it. sRGB, opaque.
        private static func c(_ hex: UInt) -> Color {
            Color(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >>  8) & 0xFF) / 255.0,
                  blue:  Double( hex        & 0xFF) / 255.0,
                  opacity: 1.0)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Accent — the one light, themeable (Settings)
    // ─────────────────────────────────────────────────────────────
    //
    // The single accent (`Palette.biolume`) reads `currentHex` from UserDefaults,
    // so picking a preset in Settings recolours the whole app. All presets are
    // BRIGHT bioluminescent tones, so `onAccent` (deep) always contrasts and the
    // "brightness IS state" rule is untouched — only the base hue shifts.
    enum Accent {
        static let key = "aeronyra.accentHex"
        static let defaultHex: UInt = 0x7FF3C8

        /// (name, hex) presets shown as swatches in Settings.
        static let presets: [(name: String, hex: UInt)] = [
            ("teal",   0x7FF3C8),   // the default
            ("aqua",   0x7FD8F3),
            ("violet", 0xB69BF3),
            ("rose",   0xF39BB5),
            ("amber",  0xF3CE7F),
            ("lime",   0xB6F37F),
        ]

        /// The chosen accent hex (defaults to the canonical teal).
        static var currentHex: UInt {
            if let v = UserDefaults.standard.object(forKey: key) as? Int, v > 0 {
                return UInt(v)
            }
            return defaultHex
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Type — two voices, one rule
    // ─────────────────────────────────────────────────────────────

    /// Newsreader — the HUMAN voice. Names, messages, invitations, titles.
    enum Serif {
        static func regular(_ size: CGFloat) -> Font { .custom("Newsreader14pt-Regular",      fixedSize: size) }
        static func italic(_ size: CGFloat) -> Font  { .custom("Newsreader14pt-Italic",       fixedSize: size) }
        static func medium(_ size: CGFloat) -> Font  { .custom("Newsreader14pt-Medium",       fixedSize: size) }
        static func mediumItalic(_ size: CGFloat) -> Font { .custom("Newsreader14pt-MediumItalic", fixedSize: size) }
    }

    /// Spline Sans Mono — the MESH whisper. Hops, timings, states. Always small,
    /// always uppercase, always tracked (see `.stillwaterMono`).
    enum Mono {
        static func regular(_ size: CGFloat) -> Font { .custom("SplineSansMono-Regular", fixedSize: size) }
        static func medium(_ size: CGFloat) -> Font  { .custom("SplineSansMono-Medium",  fixedSize: size) }
    }

    enum MonoWeight { case regular, medium }

    // ─────────────────────────────────────────────────────────────
    // MARK: Presence — depth IS reachability, brightness IS state
    // ─────────────────────────────────────────────────────────────
    //
    // The load-bearing Stillwater semantic. A later step maps the real
    // MeshPresence tiers onto these cases; this file only defines the visual
    // grade so every screen reads presence identically. Accent brightness:
    // 100% near · 60% through others · 30% relay · 0% gone. (The system-language
    // caption states 55% for "through"; the phone mockups render ~60%. We follow
    // the rendered value — tune it in ONE place here if we revisit.)
    enum Presence: CaseIterable {
        case near          // direct radio — in the room
        case throughOthers // multi-hop — a stone waits
        case relay         // beyond the water — over the relay, far
        case gone          // dark — last felt a while ago

        /// Brightness of the one accent at this depth.
        var accentOpacity: Double {
            switch self {
            case .near:          return 1.0
            case .throughOthers: return 0.6
            case .relay:         return 0.3
            case .gone:          return 0.0
            }
        }

        /// The accent light itself, dimmed to this depth. A `gone` peer has no
        /// light — callers draw a hollow `goneRing` instead.
        var light: Color { Palette.biolume.opacity(accentOpacity) }

        /// The peer's NAME color (human, serif) as it recedes into the dark.
        var nameColor: Color {
            switch self {
            case .near, .throughOthers: return Palette.foam
            case .relay:                return Palette.foamDim
            case .gone:                 return Palette.mistDim
            }
        }

        /// The peer's mesh SUBLABEL color (mono whisper) at this depth.
        var labelColor: Color {
            switch self {
            case .near, .throughOthers: return Palette.mist
            case .relay:                return Palette.mistDim
            case .gone:                 return Palette.mistDimmest
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Motion — light travels, surfaces stay still
    // ─────────────────────────────────────────────────────────────
    //
    // Breath tempo: 4–6.5s, sine-eased, desynchronized per element. Water
    // physics: heavy damping, zero overshoot. Nothing slides or bounces.
    enum Motion {
        static let breathFast: Double = 4.0
        static let breathSlow: Double = 6.5

        /// One ambient breath loop for a light. Pick a duration in
        /// [breathFast, breathSlow] and offset per element to desync.
        static func breathe(_ duration: Double = 4.0) -> Animation {
            .easeInOut(duration: duration).repeatForever(autoreverses: true)
        }

        /// The water easing — heavy damping, zero overshoot. cubic-bezier(.3,0,.1,1).
        static func water(_ duration: Double = 0.5) -> Animation {
            .timingCurve(0.3, 0, 0.1, 1, duration: duration)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - View sugar (the two voices as one-call modifiers)
// ─────────────────────────────────────────────────────────────

extension View {
    /// The MESH whisper: Spline Sans Mono, uppercase, tracked, small, in mist.
    /// Tracking is given in em (as the design specifies) and converted to points
    /// against the size, so `.24em` reads the same at any size.
    func stillwaterMono(_ size: CGFloat,
                        trackingEm: CGFloat = 0.2,
                        weight: Stillwater.MonoWeight = .regular,
                        color: Color = Stillwater.Palette.mist,
                        uppercased: Bool = true) -> some View {
        self
            .font(weight == .medium ? Stillwater.Mono.medium(size) : Stillwater.Mono.regular(size))
            .tracking(size * trackingEm)
            .textCase(uppercased ? .uppercase : nil)
            .foregroundStyle(color)
    }

    /// The HUMAN voice: Newsreader, in foam by default.
    func stillwaterSerif(_ size: CGFloat,
                         weight: Font.Weight = .regular,
                         italic: Bool = false,
                         color: Color = Stillwater.Palette.foam) -> some View {
        let font: Font = {
            switch (weight, italic) {
            case (.medium, true):  return Stillwater.Serif.mediumItalic(size)
            case (.medium, false): return Stillwater.Serif.medium(size)
            case (_, true):        return Stillwater.Serif.italic(size)
            default:               return Stillwater.Serif.regular(size)
            }
        }()
        return self.font(font).foregroundStyle(color)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Preview — the loaded-fonts smoke test
// ─────────────────────────────────────────────────────────────
//
// Drop this file in and open the canvas: if any face falls back to the system
// font, the PostScript name is wrong and it's obvious here — cheaply, before any
// real screen depends on it. This is a FONT/PALETTE self-test, not a screen.

private struct StillwaterTokensPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // — the two voices —
                VStack(alignment: .leading, spacing: 10) {
                    Text("A HUMAN WROTE IT")
                        .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    Text("Maya is near.")
                        .stillwaterSerif(30)
                    Text("the water is calm")
                        .stillwaterSerif(19, italic: true, color: Stillwater.Palette.mist)
                    Text("Confirm connection")
                        .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("THE MESH SAID IT")
                        .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    Text("AERONYRA")
                        .stillwaterMono(10.5, trackingEm: 0.42)
                    Text("via theo · 2 hops · 0.6 s")
                        .stillwaterMono(9, trackingEm: 0.18)
                    Text("over the relay · far")
                        .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
                }

                // — presence: brightness IS state —
                VStack(alignment: .leading, spacing: 14) {
                    Text("PRESENCE — DEPTH IS REACHABILITY")
                        .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    ForEach(Array(Stillwater.Presence.allCases.enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 16) {
                            light(for: p).frame(width: 20)
                            Text(name(for: p)).stillwaterSerif(21, color: p.nameColor)
                            Spacer()
                            Text(label(for: p)).stillwaterMono(8.5, trackingEm: 0.18, color: p.labelColor)
                        }
                    }
                }

                // — palette —
                VStack(alignment: .leading, spacing: 10) {
                    Text("COLOR — ONE LIGHT, MANY DEPTHS")
                        .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    swatch("ABYSS #050B0A", Stillwater.Palette.abyss)
                    swatch("WATER #0A1514", Stillwater.Palette.water)
                    swatch("SHALLOW #12211E", Stillwater.Palette.shallow)
                    swatch("FOAM #E9F5EF", Stillwater.Palette.foam)
                    swatch("MIST #8FA8A0", Stillwater.Palette.mist)
                    swatch("BIOLUMINESCENCE #7FF3C8", Stillwater.Palette.biolume)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Stillwater.Palette.abyss)
    }

    @ViewBuilder private func light(for p: Stillwater.Presence) -> some View {
        if p == .gone {
            Circle().strokeBorder(Stillwater.Palette.goneRing, lineWidth: 1)
                .frame(width: 13, height: 13)
        } else {
            Circle().fill(p.light)
                .frame(width: 13, height: 13)
                .shadow(color: p.light.opacity(0.6), radius: 6)
        }
    }

    private func name(for p: Stillwater.Presence) -> String {
        switch p {
        case .near:          return "Theo"
        case .throughOthers: return "Maya"
        case .relay:         return "Jun"
        case .gone:          return "Sana"
        }
    }

    private func label(for p: Stillwater.Presence) -> String {
        switch p {
        case .near:          return "in the room · direct"
        case .throughOthers: return "through theo · 2 hops"
        case .relay:         return "over the relay · far"
        case .gone:          return "last felt 3 h ago"
        }
    }

    @ViewBuilder private func swatch(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .frame(width: 40, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.1)))
            Text(title).stillwaterMono(10, trackingEm: 0.12)
        }
    }
}

#Preview("Stillwater — tokens") {
    StillwaterTokensPreview()
}
