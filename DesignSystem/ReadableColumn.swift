//
//  ReadableColumn.swift
//  DesignSystem
//
//  Caps a screen's content to a centered readable column so it doesn't
//  stretch edge-to-edge on iPad / large windows. The app background fills
//  the full screen behind the column; the content centers within it.
//
//  A no-op on phones — their width is already under the cap, so the column
//  simply fills the screen exactly as before.
//

import SwiftUI

extension View {

    /// Wrap the view in the full-bleed app background and cap its width to a
    /// centered readable column. Apply at a screen's root (replacing a
    /// `.background(Color.bgApp…)`), e.g. `someVStack.readableColumn()`.
    func readableColumn(maxWidth: CGFloat = 640) -> some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()
            self.frame(maxWidth: maxWidth)
        }
    }
}
