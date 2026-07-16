//
//  PTTSessionCrypto.swift
//  Core/Media
//
//  Step 2 of BLE-live push-to-talk: the per-session frame crypto. PURE crypto —
//  no transport, no audio, no UI. A live voice stream cannot ride the per-message
//  Signal ratchet (ratcheting 25–50 frames/sec is the wrong primitive), so:
//
//    • ONE handshake hands over a random 32-byte session secret S (sealed over
//      the existing Signal session — that SEND is the transport step, not here;
//      this file provides only the derivation + framing).
//    • DIRECTIONAL keys via HKDF-SHA256 (salt empty; version + direction in the
//      info label) — a single shared key would let both parties start at
//      counter 0 under the same key, which is catastrophic nonce reuse. Two keys
//      keep each direction's (key, nonce) space disjoint.
//    • PER-FRAME ChaCha20-Poly1305 with a monotonic UInt64 counter — no
//      ratchet. Nonce = 0x00000000 ‖ BE64(counter). The sealer throws before the
//      counter could wrap, so a (key, nonce) pair is never reused.
//    • A 64-wide anti-replay window on the receiver (RFC 6479 bitmap in one
//      UInt64): reject duplicates and too-old frames, permit in-window reorder
//      (the lossy BLE path reorders slightly). The window advances ONLY on
//      authenticated frames, so a forged counter can't shift it.
//
//  Every constant here is pinned by external known-answer vectors
//  (BeaconTests/Fixtures/ptt_kat_vectors.json, produced by tools/ptt_kat_gen.py
//  against RFC 8439 + RFC 5869 ground truth). See THREAT_MODEL for the argument.
//

import Foundation
import CryptoKit

public enum PTTSessionCryptoError: Error, Equatable {
    /// The frame counter reached its ceiling; sealing more would risk a nonce
    /// reuse. The session must be torn down / re-handshaked, never wrapped.
    case counterCeiling
    /// The frame's counter is a duplicate or older than the replay window.
    case replayed
    /// AEAD tag verification failed — forged, corrupted, or wrong key.
    case authenticationFailed
}

public enum PTTSessionCrypto {
    public static let keyByteCount = 32

    /// The exact info labels the directional keys are derived under. The bytes
    /// are pinned by the KAT — changing them re-keys the wire.
    public static let infoInitiatorToResponder = Data("aeronyra.ptt.v1|initiator->responder".utf8)
    public static let infoResponderToInitiator = Data("aeronyra.ptt.v1|responder->initiator".utf8)

    /// Derive the two directional session keys from the handshake secret `S`.
    /// salt is empty; the info label carries version + direction. The returned
    /// keys are named from the INITIATOR's viewpoint (the responder swaps them):
    ///   initiatorToResponder — the initiator seals with this, responder opens.
    ///   responderToInitiator — the responder seals with this, initiator opens.
    public static func directionalKeys(secret: SymmetricKey)
        -> (initiatorToResponder: SymmetricKey, responderToInitiator: SymmetricKey) {
        let a = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: Data(),
                                       info: infoInitiatorToResponder,
                                       outputByteCount: keyByteCount)
        let b = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: Data(),
                                       info: infoResponderToInitiator,
                                       outputByteCount: keyByteCount)
        return (a, b)
    }

    /// The pinned 12-byte nonce: 0x00000000 ‖ BE64(counter).
    static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: counter.bigEndian) { src in
            for i in 0..<8 { bytes[4 + i] = src[i] }
        }
        // 12 bytes is always a valid ChaChaPoly nonce.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

// MARK: - Sender: monotonic-counter frame sealer

/// One sealer per (session, direction). Not thread-safe — the capture path
/// drives it on a single audio thread.
public final class PTTFrameSealer {
    private let key: SymmetricKey
    private var counter: UInt64

    public init(key: SymmetricKey) {
        self.key = key
        self.counter = 0
    }

    /// Testing/handshake hook: start from a specific counter. Production callers
    /// use `init(key:)` (counter 0).
    internal init(key: SymmetricKey, counter: UInt64) {
        self.key = key
        self.counter = counter
    }

    /// The counter the NEXT `seal` will use (before it increments).
    public var nextCounter: UInt64 { counter }

    /// Seal one frame under the current counter, then advance. Monotonic, +1 per
    /// call, no ratchet. Throws `counterCeiling` rather than ever reuse a nonce.
    /// `aad` is authenticated-not-encrypted (the frame's `BE64(seq)` header).
    public func seal(_ plaintext: Data, aad: Data = Data())
        throws -> (counter: UInt64, ciphertext: Data, tag: Data) {
        guard counter != UInt64.max else { throw PTTSessionCryptoError.counterCeiling }
        let c = counter
        let box = try ChaChaPoly.seal(plaintext, using: key,
                                      nonce: PTTSessionCrypto.nonce(counter: c),
                                      authenticating: aad)
        counter += 1
        return (c, box.ciphertext, box.tag)
    }
}

// MARK: - The live-send seam (initiator-open → capture pipeline, Part B)

/// The ONE-SHOT handoff from the coordinator's initiator-open to the capture
/// pipeline: the per-session frame sealer plus a role-agnostic send closure
/// already bound to ONE resolved BLE link (I6 — never both GATT roles).
///
/// `@unchecked Sendable`: `PTTFrameSealer` is a non-Sendable class, but the
/// sealer is render-thread-confined (I2) — the coordinator derives the send key
/// and constructs the sealer INSIDE its actor, hands this handle out exactly
/// once at session-open, and retains no reference; thereafter only the capture
/// tap thread touches it. `send` is fire-and-forget into the transport's queue.
struct PTTLiveSend: @unchecked Sendable {
    let sealer: PTTFrameSealer
    let send: @Sendable (Data) -> Void
    /// The session id this handle belongs to — NON-secret (safe to log), minted
    /// at initiator-open. Carried so a close can name ITS OWN session instead
    /// of "whatever is open toward that peer": a stale hold's close keyed by
    /// peer alone can pull a LATER press's id from the per-peer slot and kill
    /// the live session mid-hold (see `closePTTInitiator(toPeer:pttID:)`).
    let pttID: Data
}

// MARK: - Receiver: authenticate-then-anti-replay opener

/// One opener per (session, direction). Not thread-safe — driven on the receive
/// path's single thread.
public final class PTTFrameOpener {
    private let key: SymmetricKey
    private var highest: UInt64 = 0     // highest counter accepted so far
    private var bitmap: UInt64 = 0      // bit i set ⇒ (highest - i) accepted
    private var seenAny = false

    /// The anti-replay window width (RFC 6479 bitmap in one UInt64).
    public static let windowSize: UInt64 = 64

    public init(key: SymmetricKey) { self.key = key }

    /// Open a received frame. Order is deliberate: reject obvious replays first
    /// (cheap, before spending an AEAD verify), then authenticate, and only
    /// advance the window on an AUTHENTIC frame — so a forged counter can never
    /// shift the window and starve legitimate frames.
    public func open(counter: UInt64, ciphertext: Data, tag: Data, aad: Data = Data())
        throws -> Data {
        try checkReplay(counter)
        let box = try ChaChaPoly.SealedBox(nonce: PTTSessionCrypto.nonce(counter: counter),
                                           ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw PTTSessionCryptoError.authenticationFailed
        }
        commit(counter)
        return plaintext
    }

    /// Throws `.replayed` for a duplicate or a too-old counter. Never mutates.
    private func checkReplay(_ counter: UInt64) throws {
        guard seenAny else { return }            // first frame is always fresh
        if counter > highest { return }          // strictly newer → fresh
        let diff = highest - counter
        if diff >= Self.windowSize { throw PTTSessionCryptoError.replayed }   // too old
        if (bitmap >> diff) & 1 == 1 { throw PTTSessionCryptoError.replayed } // duplicate
    }

    /// Record an accepted counter (called only after authentication).
    private func commit(_ counter: UInt64) {
        if !seenAny {
            seenAny = true
            highest = counter
            bitmap = 1
            return
        }
        if counter > highest {
            let shift = counter - highest
            bitmap = shift >= Self.windowSize ? 0 : (bitmap << shift)
            bitmap |= 1
            highest = counter
        } else {
            bitmap |= (1 << (highest - counter))
        }
    }
}
