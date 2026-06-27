//
//  SignalBars.swift
//  DesignSystem
//
//  Three ascending bars; the first N lit, the rest dimmed (DESIGN_TOKENS §10).
//
//  Used inline beside any reachability label and inside the DeliveryReceipt's
//  status line. The COLOR comes from the caller — green for direct/healthy,
//  amber for relayed, red for an error path. This component is purely about
//  drawing the three bars; choosing which color to pass is the caller's job
//  (and is what the Quiet Rule governs at the call site).
//

import SwiftUI

struct SignalBars: View {

    /// Connection quality. The integer raw value doubles as "how many bars
    /// are lit," matching the spec's prop description (1 weak / 2 fair /
    /// 3 good).
    enum Strength: Int, CaseIterable, Sendable {
        case weak = 1
        case fair = 2
        case good = 3
    }

    let strength: Strength

    /// The lit color. Unlit bars are this same color at 22% opacity per spec,
    /// so the bars read as one element rather than separate shapes.
    let color: Color

    // MARK: - Spec constants

    /// Unlit bars in DESIGN_TOKENS §6 are described as "22% opacity."
    private static let unlitOpacity: Double = 0.22

    private static let barCount: Int = 3
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    /// Height of the shortest (leftmost) bar.
    private static let baseHeight: CGFloat = 4
    /// How much taller each subsequent bar grows.
    private static let heightStep: CGFloat = 3

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .opacity(i < strength.rawValue ? 1.0 : Self.unlitOpacity)
                    .frame(
                        width:  Self.barWidth,
                        height: Self.baseHeight + CGFloat(i) * Self.heightStep
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: strength))
    }

    private static func accessibilityLabel(for strength: Strength) -> String {
        switch strength {
        case .weak: return "Signal weak"
        case .fair: return "Signal fair"
        case .good: return "Signal good"
        }
    }
}

// MARK: - Previews

#Preview("Signal strengths") {
    VStack(spacing: 24) {

        // The three strengths, each in its semantic color.
        HStack(spacing: 20) {
            VStack(spacing: 6) {
                SignalBars(strength: .weak, color: .statusError)
                Text("weak")
                    .font(Typography.deliveryChip)
                    .foregroundStyle(Color.textSecondary)
            }
            VStack(spacing: 6) {
                SignalBars(strength: .fair, color: .statusRelay)
                Text("fair")
                    .font(Typography.deliveryChip)
                    .foregroundStyle(Color.textSecondary)
            }
            VStack(spacing: 6) {
                SignalBars(strength: .good, color: .statusHealthy)
                Text("good")
                    .font(Typography.deliveryChip)
                    .foregroundStyle(Color.textSecondary)
            }
        }

        // A row showing the bars beside a label, as they appear in receipts.
        HStack(spacing: 6) {
            SignalBars(strength: .good, color: .statusHealthy)
            Text("Direct · good")
                .font(Typography.receiptStatus)
                .foregroundStyle(Color.textSecondary)
        }
    }
    .padding(32)
    .background(Color.bgApp)
    .preferredColorScheme(.dark)
}
