//
//  SwipeRevealRow.swift
//  Beacon
//
//  Swipe left on a Home row to reveal its actions side by side (Guideline
//  1.2: Block and Report; Unblock and Report on a blocked chat; none on a
//  reported one). Home's rows live in a ScrollView, not a List, so SwiftUI's
//  `swipeActions` is unavailable; this is a small horizontal-only drag.
//  One row open at a time (`openID`, owned by Home); a tap anywhere closes
//  it, and a tap on an open row closes it instead of opening the chat.
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group).
//

import SwiftUI

struct SwipeRevealAction: Identifiable {
    enum Style { case plain, destructive }
    let title: String
    let style: Style
    let action: () -> Void
    var id: String { title }
}

/// The open/close decision, kept pure so it can be tested.
enum SwipeReveal {
    static let buttonWidth: CGFloat = 78

    /// Where a drag that ended at `translation` leaves the row: open when it
    /// travelled past a third of the actions' width to the left (or, from
    /// open, didn't travel back past a third).
    static func settlesOpen(translation: CGFloat, wasOpen: Bool, revealWidth: CGFloat) -> Bool {
        guard revealWidth > 0 else { return false }
        let start: CGFloat = wasOpen ? -revealWidth : 0
        return start + translation < -revealWidth / 3
    }

    /// The row's offset while dragging, clamped to [-revealWidth, 0].
    static func offset(translation: CGFloat, wasOpen: Bool, revealWidth: CGFloat) -> CGFloat {
        let start: CGFloat = wasOpen ? -revealWidth : 0
        return min(0, max(-revealWidth, start + translation))
    }
}

struct SwipeRevealRow<Content: View>: View {
    let id: Data
    @Binding var openID: Data?
    let actions: [SwipeRevealAction]
    @ViewBuilder let content: Content

    @State private var dragging: CGFloat?

    private var revealWidth: CGFloat { CGFloat(actions.count) * SwipeReveal.buttonWidth }
    private var isOpen: Bool { openID == id }
    private var offset: CGFloat {
        if let dragging {
            return SwipeReveal.offset(translation: dragging, wasOpen: isOpen, revealWidth: revealWidth)
        }
        return isOpen ? -revealWidth : 0
    }

    var body: some View {
        if actions.isEmpty {
            content
        } else {
            ZStack(alignment: .trailing) {
                buttons
                    .frame(width: -offset, alignment: .trailing)
                    .clipped()
                content
                    .offset(x: offset)
                    .overlay {
                        // Any row open: a tap closes it rather than opening a chat.
                        if openID != nil {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { openID = nil } }
                        }
                    }
            }
            .simultaneousGesture(drag)
            .animation(.easeOut(duration: 0.2), value: isOpen)
        }
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(actions) { a in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { openID = nil }
                    a.action()
                } label: {
                    Text(a.title)
                        .font(Stillwater.Serif.regular(15))
                        .foregroundStyle(a.style == .destructive ? Stillwater.Palette.foam : Stillwater.Palette.biolume)
                        .frame(width: SwipeReveal.buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(a.style == .destructive
                                    ? Color(hue: 0.02, saturation: 0.62, brightness: 0.62)
                                    : Stillwater.Palette.shallow)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Horizontal-only: a mostly vertical drag is left to the scroll view.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { v in
                guard dragging != nil || abs(v.translation.width) > abs(v.translation.height) else { return }
                if dragging == nil, !isOpen, openID != nil { openID = nil }
                dragging = v.translation.width
            }
            .onEnded { v in
                guard dragging != nil else { return }
                let open = SwipeReveal.settlesOpen(translation: v.translation.width,
                                                   wasOpen: isOpen, revealWidth: revealWidth)
                withAnimation(.easeOut(duration: 0.2)) {
                    dragging = nil
                    if open { openID = id } else if isOpen { openID = nil }
                }
            }
    }
}
