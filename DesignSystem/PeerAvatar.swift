//
//  PeerAvatar.swift
//  DesignSystem
//
//  The identity disc — ONE source of truth for how a peer is drawn as an
//  avatar, used by the Conversation header, the Chats list, and anywhere else
//  a peer needs a face. Previously this gradient-circle treatment was copied
//  inline in several rows; centralizing it means a single place to evolve.
//
//  WHAT IT RENDERS (DESIGN_TOKENS §1 / §11):
//   • A circle filled with the locked avatar gradient (LinearGradient.avatarBrand),
//     hue-rotated deterministically from the peer's public key (Peer.avatarHue) —
//     so the same person is the same color on every screen, every launch.
//   • An INITIAL overlaid ONLY when the peer has a real, user-set petname. For an
//     unnamed peer `displayLabel` is a hex fingerprint (e.g. "a3·9f·2c"), whose
//     first character ("a") would be meaningless — so those fall back to a neutral
//     person glyph instead of a misleading letter.
//
//  LOCAL-ONLY BY DESIGN: nothing here comes over the wire. Hue is derived from the
//  public key; the initial is derived from the LOCAL petname the user assigned.
//  A future custom photo (local contact customization) overrides the gradient here,
//  in this one component — so the header, list, and rows all pick it up at once.
//

import SwiftUI
import UIKit

struct PeerAvatar: View {

    /// The peer to draw. Optional so callers with a peerless conversation
    /// (e.g. a mesh room) can still render a neutral disc.
    let peer: Peer?

    /// Diameter in points. 34 in the conversation header, 38 in list rows
    /// (matches the prior inline treatment).
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = customImage {
                // Local custom photo (never transmitted) takes priority over the
                // gradient. Filled + clipped to the disc so any aspect ratio sits
                // cleanly in the circle.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient.avatarBrand)
                    .hueRotation(.degrees(hueDegrees))
                    .frame(width: size, height: size)
                    .overlay(overlayContent)
            }
        }
    }

    // MARK: - Custom photo

    /// The user's locally-chosen photo for this peer, if set and decodable.
    /// Nil → fall back to the gradient treatment below.
    private var customImage: UIImage? {
        guard let data = peer?.customAvatarData else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Hue

    /// Deterministic hue rotation from the peer's key, or the user's chosen
    /// accent (`resolvedHue`). 0 (no rotation) when there is no peer, so a mesh
    /// room reads as the base brand disc.
    private var hueDegrees: Double {
        guard let peer else { return 0 }
        return peer.resolvedHue * 360
    }

    // MARK: - Overlay (initial or fallback glyph)

    @ViewBuilder
    private var overlayContent: some View {
        if let initial {
            Text(initial)
                .font(.custom("Geist-Bold", size: size * 0.40))
                .foregroundStyle(Color.avatarText)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.44, weight: .regular))
                .foregroundStyle(Color.avatarText.opacity(0.9))
        }
    }

    /// The initial to show, or nil when the peer has no real petname (unnamed
    /// peers fall back to the glyph rather than a hex character). Guards against
    /// the `displayLabel` fingerprint form by requiring a non-empty `displayName`.
    private var initial: String? {
        guard let name = peer?.displayName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty,
              let first = name.first else {
            return nil
        }
        return String(first).uppercased()
    }
}
