// CallSignal.swift
// Core/Calls
//
// The pure codec for FaceTime-v1 (voice-only) call-signaling BODIES. This is
// the calls counterpart to the ack / nostr-identity / invite-echo body codecs
// in MessagePayload.swift: strict, length-checked parsers on the untrusted
// receive path, and builders that produce exactly the bytes a sealed payload
// carries. PURE LOGIC — no transport, no crypto, no WebRTC, no SwiftData — so
// it is fully unit-testable on the Mac.
//
// WIRE PLACEMENT (deferred, deliberately): the three signal kinds will occupy
// WirePayloadKind tags 8 (request), 9 (answer), 10 (decline) beside text/ack.
// Those enum cases — and the strict-verified 7f gate extension that keeps an
// unverified session-holder from ringing us — land in MessagePayload.swift and
// FirstContactCoordinator.swift in a LATER step, after the in-flight stories
// work in the coordinator commits (two features must never interleave edits in
// one file while either is uncommitted). Until then this file stands alone.
//
// SECURITY SHAPE: a request/answer body carries the complete SDP, and the SDP
// carries the DTLS-SRTP certificate fingerprint (`a=fingerprint:` line). The
// whole body is sealed under the existing Signal session to the verified
// contact, exactly like a text message — so the media keys are authenticated
// by the existing trust root. No new trust root, no call server.
//
// NON-TRICKLE ICE (LOCKED for v1): each side gathers ALL its candidates and
// sends ONE complete SDP. Signaling rides the relay path when out of BLE
// range, where each leg costs seconds — trickling candidates would multiply
// that latency for nothing. One sealed round trip total: request → answer.
//

import Foundation

// MARK: - CallSignal

/// One call-signaling frame, decoded from (or encodable to) a sealed payload
/// body. `callID` ties every frame of one call attempt together, so a stale
/// or replayed frame from an earlier attempt is ignored by the state machine.
public enum CallSignal: Equatable, Sendable {

    /// Caller → callee: "X wants to FaceTime". Body: callID(16) ‖ SDP offer.
    case request(callID: Data, sdp: String)

    /// Callee → caller, on Accept. Body: callID(16) ‖ SDP answer.
    case answer(callID: Data, sdp: String)

    /// Callee → caller, on Decline (also: hang-up before connect). Body:
    /// exactly callID(16). Carries no SDP — there is nothing to negotiate.
    case decline(callID: Data)
}

// MARK: - Layout constants

public extension CallSignal {

    /// Byte length of a call id — 16 CSPRNG bytes, same shape as a MessageID /
    /// mediaID, minted fresh per call attempt by the caller.
    static var callIDByteCount: Int { 16 }

    /// Defensive ceiling on an SDP body (mirrors `manifestWithinBounds`'
    /// posture): a real voice-only offer with gathered candidates is a few KB;
    /// 32 KiB is far above any legitimate SDP and far below anything that
    /// could stress the payload buckets. A parse above it returns nil.
    static var maxSDPBytes: Int { 32 * 1024 }
}

// MARK: - Encode

public extension CallSignal {

    /// The exact body bytes a sealed call payload carries (the counterpart of
    /// the parsers below). The payload KIND is not encoded here — it is the
    /// wire tag byte, owned by MessagePayload.
    func encodedBody() -> Data {
        switch self {
        case .request(let callID, let sdp), .answer(let callID, let sdp):
            var out = Data(capacity: Self.callIDByteCount + sdp.utf8.count)
            out.append(callID)
            out.append(contentsOf: sdp.utf8)
            return out
        case .decline(let callID):
            return callID
        }
    }
}

// MARK: - Strict parsers (untrusted receive path)

public extension CallSignal {

    /// Parse a `.request` body: callID(16) ‖ UTF-8 SDP. Returns nil on a short
    /// buffer, an empty SDP, an oversize SDP, or bytes that are not UTF-8 —
    /// the caller ignores a malformed frame, sends nothing back.
    static func parseRequestBody(_ body: Data) -> CallSignal? {
        guard let (callID, sdp) = splitIDAndSDP(body) else { return nil }
        return .request(callID: callID, sdp: sdp)
    }

    /// Parse an `.answer` body: callID(16) ‖ UTF-8 SDP. Same strictness as
    /// `parseRequestBody`.
    static func parseAnswerBody(_ body: Data) -> CallSignal? {
        guard let (callID, sdp) = splitIDAndSDP(body) else { return nil }
        return .answer(callID: callID, sdp: sdp)
    }

    /// Parse a `.decline` body: exactly callID(16), nothing else. Returns nil
    /// on any other length.
    static func parseDeclineBody(_ body: Data) -> CallSignal? {
        guard body.count == callIDByteCount else { return nil }
        return .decline(callID: Data(body))
    }

    /// Shared strict split for the two SDP-carrying kinds.
    private static func splitIDAndSDP(_ body: Data) -> (callID: Data, sdp: String)? {
        guard body.count > callIDByteCount,
              body.count <= callIDByteCount + maxSDPBytes else { return nil }
        let bytes = [UInt8](body)
        let callID = Data(bytes[0..<callIDByteCount])
        guard let sdp = String(bytes: bytes[callIDByteCount...], encoding: .utf8),
              !sdp.isEmpty else { return nil }
        return (callID, sdp)
    }
}

// MARK: - Accessors

public extension CallSignal {

    /// The id tying this frame to its call attempt.
    var callID: Data {
        switch self {
        case .request(let id, _), .answer(let id, _), .decline(let id):
            return id
        }
    }

    /// The SDP this frame carries, if its kind carries one.
    var sdp: String? {
        switch self {
        case .request(_, let sdp), .answer(_, let sdp): return sdp
        case .decline:                                  return nil
        }
    }
}
