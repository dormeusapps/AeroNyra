//
//  OpusVoiceCodec.swift
//  Core/Media
//
//  Step 1 of BLE-live push-to-talk: the Opus codec seam. Pure codec — no BLE,
//  no crypto, no capture (those are later steps). Wraps the vendored Xiph Opus
//  1.5.2 (Vendor/opus, BSD-3, SHA-256-verified) behind a small Swift surface.
//
//  Geometry is fixed and load-bearing for the wire: 48 kHz mono, 20 ms frames
//  (960 samples), 24 kbps VOIP. Inband FEC is ON and packet-loss-perc > 0 so the
//  encoder embeds a low-bitrate copy of each frame in the next packet — the
//  packet-loss insurance the lossy BLE path depends on. The decoder supports
//  both FEC recovery (decode the next packet with `fec: true`) and PLC
//  (`decode(nil)`), which the drop-late receiver relies on.
//

import Foundation
import Opus

public enum OpusVoiceCodecError: Error, Equatable {
    case encoderInit(Int32)
    case decoderInit(Int32)
    case encode(Int32)
    case decode(Int32)
    case badFrameLength(Int)
}

public enum OpusVoiceCodec {
    /// The one geometry the whole PTT wire is built around. Changing any of
    /// these is a wire-breaking change (the KAT pins them).
    public static let sampleRate: Int32 = 48_000
    public static let channels: Int32 = 1
    public static let frameMs: Int = 20
    public static let samplesPerFrame: Int = 960        // 48_000 * 0.020
    public static let bitrate: Int32 = 24_000
    /// Opus's recommended upper bound for a single encoded frame buffer.
    public static let maxPacketBytes: Int = 4_000

    // MARK: Encoder

    public final class Encoder {
        private let enc: OpaquePointer

        public init(bitrate: Int32 = OpusVoiceCodec.bitrate) throws {
            var err: Int32 = 0
            guard let e = opus_encoder_create(OpusVoiceCodec.sampleRate,
                                              OpusVoiceCodec.channels,
                                              OPUS_APPLICATION_VOIP, &err),
                  err == OPUS_OK else {
                throw OpusVoiceCodecError.encoderInit(err)
            }
            enc = e
            _ = beacon_opus_encoder_set_bitrate(e, bitrate)
            _ = beacon_opus_encoder_set_signal_voice(e)
            _ = beacon_opus_encoder_set_complexity(e, 8)
            // Packet-loss resilience for the lossy BLE path.
            _ = beacon_opus_encoder_set_inband_fec(e, 1)
            _ = beacon_opus_encoder_set_packet_loss_perc(e, 10)
        }

        /// Encode exactly one 20 ms frame (960 mono Int16 samples) → one packet.
        public func encode(_ pcm: [Int16]) throws -> Data {
            guard pcm.count == OpusVoiceCodec.samplesPerFrame else {
                throw OpusVoiceCodecError.badFrameLength(pcm.count)
            }
            var out = [UInt8](repeating: 0, count: OpusVoiceCodec.maxPacketBytes)
            let n = pcm.withUnsafeBufferPointer { pin in
                out.withUnsafeMutableBufferPointer { pout in
                    opus_encode(enc, pin.baseAddress!,
                                Int32(OpusVoiceCodec.samplesPerFrame),
                                pout.baseAddress!,
                                Int32(OpusVoiceCodec.maxPacketBytes))
                }
            }
            guard n > 0 else { throw OpusVoiceCodecError.encode(n) }
            return Data(out[0..<Int(n)])
        }

        /// Current encoder bitrate (bps) as Opus reports it — used by the KAT.
        public func currentBitrate() -> Int32 {
            var v: Int32 = 0
            _ = beacon_opus_encoder_get_bitrate(enc, &v)
            return v
        }

        deinit { opus_encoder_destroy(enc) }
    }

    // MARK: Decoder

    public final class Decoder {
        private let dec: OpaquePointer

        public init() throws {
            var err: Int32 = 0
            guard let d = opus_decoder_create(OpusVoiceCodec.sampleRate,
                                              OpusVoiceCodec.channels, &err),
                  err == OPUS_OK else {
                throw OpusVoiceCodecError.decoderInit(err)
            }
            dec = d
        }

        /// Decode one packet → 960 mono Int16 samples.
        /// - `packet == nil` runs packet-loss concealment (PLC) — the drop-late
        ///   receiver plays a concealed frame when nothing arrived in time.
        /// - `fec == true` pulls the inband-FEC copy of the PREVIOUS (lost)
        ///   frame out of `packet` instead of decoding `packet`'s own frame.
        public func decode(_ packet: Data?, fec: Bool = false) throws -> [Int16] {
            var out = [Int16](repeating: 0, count: OpusVoiceCodec.samplesPerFrame)
            let n: Int32
            if let packet {
                n = packet.withUnsafeBytes { raw in
                    out.withUnsafeMutableBufferPointer { pout in
                        opus_decode(dec,
                                    raw.bindMemory(to: UInt8.self).baseAddress,
                                    Int32(packet.count),
                                    pout.baseAddress!,
                                    Int32(OpusVoiceCodec.samplesPerFrame),
                                    fec ? 1 : 0)
                    }
                }
            } else {
                // PLC: NULL data, concealment length = one frame.
                n = out.withUnsafeMutableBufferPointer { pout in
                    opus_decode(dec, nil, 0, pout.baseAddress!,
                                Int32(OpusVoiceCodec.samplesPerFrame),
                                fec ? 1 : 0)
                }
            }
            guard n > 0 else { throw OpusVoiceCodecError.decode(n) }
            return Array(out[0..<Int(n)])
        }

        deinit { opus_decoder_destroy(dec) }
    }
}
