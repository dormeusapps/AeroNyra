// EnvelopeSeal.swift
// Security/Session
//
// ENVELOPE SEAL v1 — every session message is sealed to the RECIPIENT's
// identity key before it leaves this device, so a phone that relays it sees
// neither the sender's identity key (which a libsignal PreKeySignalMessage
// carries in the clear) nor the message-type byte that marks first contact.
// Every sealed message has the same shape; nothing tells a relayer which kind
// it is. FLAG DAY: an unsealed message is refused (see SignalSession.open).
//
// FORMAT (LOCKED; vectors: tools/gen_envelope_seal_kat.py →
// BeaconTests/EnvelopeSealKATVectors.swift):
//
//   sealed      = 0x01 ‖ eph_pub(32) ‖ ChaCha20-Poly1305(key, nonce, inner, aad)  (ct ‖ tag16)
//   shared      = X25519(eph_priv, recipient_pub)         all-zero → refused
//   key ‖ nonce = HKDF-SHA256(ikm: shared, salt: empty,
//                             info: LABEL ‖ 0x01 ‖ eph_pub ‖ recipient_pub, L: 44)
//   aad         = 0x01 ‖ eph_pub
//   LABEL       = "AeroNyra/envelope-seal/v1"
//
// A FRESH ephemeral key per message, so the derived nonce never repeats under
// a key. The recipient's X25519 public key is its raw 32-byte identity key.
// No forward secrecy for THIS layer (it hides metadata from relayers; the
// inner libsignal ratchet keeps its own).
//

import CryptoKit
import Foundation

enum EnvelopeSeal {

    static let version: UInt8 = 0x01
    static let label = Data("AeroNyra/envelope-seal/v1".utf8)
    /// 1 version byte + 32 ephemeral key + 16 tag.
    static let overhead = 1 + 32 + 16

    enum SealError: Error, Equatable {
        case notSealed            // wrong version byte or too short — the flag day refusal
        case invalidPublicKey     // not a usable X25519 key
        case weakSharedSecret     // all-zero X25519 output (low-order point)
        case authenticationFailed // not for us, or altered
    }

    /// Seal `inner` to `recipient` (raw 32-byte X25519 identity key) under a
    /// FRESH ephemeral key.
    static func seal(_ inner: Data, to recipient: Data) throws -> Data {
        try seal(inner, to: recipient, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }

    #if DEBUG
    /// TEST-ONLY: seal under a GIVEN ephemeral key (the known-answer vectors).
    /// Compiled out of Release, so production can only ever use a fresh key.
    static func sealForTesting(_ inner: Data, to recipient: Data,
                               ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        try seal(inner, to: recipient, ephemeral: ephemeral)
    }
    #endif

    private static func seal(_ inner: Data, to recipient: Data,
                             ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let ephPub = ephemeral.publicKey.rawRepresentation
        let (key, nonce) = try derive(ephemeral: ephemeral, peer: recipient,
                                      ephPub: ephPub, recipientPub: recipient)
        let aad = Data([version]) + ephPub
        let box = try ChaChaPoly.seal(inner, using: key, nonce: nonce, authenticating: aad)
        return Data([version]) + ephPub + box.ciphertext + box.tag
    }

    /// Open a sealed message addressed to us. Throws on anything that is not a
    /// v1 seal for our key — the caller drops it quietly.
    static func open(_ sealed: Data, with ours: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard sealed.count >= overhead, sealed.first == version else { throw SealError.notSealed }
        let bytes = Data(sealed)                       // re-base indices to 0
        let ephPub = bytes.subdata(in: 1..<33)
        let ciphertext = bytes.subdata(in: 33..<(bytes.count - 16))
        let tag = bytes.subdata(in: (bytes.count - 16)..<bytes.count)
        let (key, nonce) = try derive(ephemeral: ours, peer: ephPub,
                                      ephPub: ephPub, recipientPub: ours.publicKey.rawRepresentation)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: Data([version]) + ephPub)
        } catch {
            throw SealError.authenticationFailed
        }
    }

    /// X25519 → HKDF-SHA256 → (key, nonce). `ephemeral`/`peer` are whichever
    /// pair this side holds (sender: eph_priv × recipient_pub; recipient:
    /// our_priv × eph_pub); the info binding is the same on both sides.
    private static func derive(ephemeral: Curve25519.KeyAgreement.PrivateKey, peer: Data,
                               ephPub: Data, recipientPub: Data) throws -> (SymmetricKey, ChaChaPoly.Nonce) {
        let peerKey: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
            shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)
        } catch {
            throw SealError.invalidPublicKey
        }
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        guard sharedBytes.contains(where: { $0 != 0 }) else { throw SealError.weakSharedSecret }
        let info = label + Data([version]) + ephPub + recipientPub
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedBytes),
                                         salt: Data(), info: info, outputByteCount: 44)
        let okmBytes = okm.withUnsafeBytes { Data($0) }
        let nonce = try ChaChaPoly.Nonce(data: okmBytes.subdata(in: 32..<44))
        return (SymmetricKey(data: okmBytes.subdata(in: 0..<32)), nonce)
    }
}
