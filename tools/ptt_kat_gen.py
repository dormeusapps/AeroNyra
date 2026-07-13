#!/usr/bin/env python3
"""
ptt_kat_gen.py — the SINGLE reference generator for the PTT session-crypto
known-answer vectors (BLE-live step 2).

Uses pyca/cryptography (OpenSSL-backed) — an implementation independent of
Apple CryptoKit, which the Swift under test uses. The Swift test loads the
emitted JSON and asserts CryptoKit reproduces these bytes EXACTLY; it never
computes its own expected values.

Before emitting anything, this script asserts pyca reproduces two published RFC
ground-truth vectors:
  • RFC 8439 §2.8.2  — ChaCha20-Poly1305 AEAD
  • RFC 5869 Test Case 1 — HKDF-SHA256
If pyca can't reproduce the RFCs, the generator is wrong and aborts before
writing. Those RFC vectors are also carried into the output JSON so CryptoKit is
checked against RFC ground truth directly.

Design pinned by the emitted vectors (matches Core/Media/PTTSessionCrypto.swift):
  • Session secret S: random 32 B in production; a FIXED test value here so the
    vectors are deterministic and committable.
  • Directional keys, HKDF-SHA256, salt = EMPTY, version+direction in `info`:
        K_send = HKDF(S, salt=b"", info=b"aeronyra.ptt.v1|initiator->responder")
        K_recv = HKDF(S, salt=b"", info=b"aeronyra.ptt.v1|responder->initiator")
  • Per-frame AEAD: ChaCha20-Poly1305(frame, key=K_dir, nonce=enc(counter), aad).
        nonce = 0x00000000 ‖ BE64(counter)   (12 B)
        aad   = BE64(seq)  (or empty)
        counter is a monotonic UInt64, +1 per frame (no per-frame ratchet).

Run:  python3 tools/ptt_kat_gen.py
Out:  BeaconTests/Fixtures/ptt_kat_vectors.json   (+ a summary to stdout)
"""

import hashlib
import json
import os
import struct
import sys

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

H = bytes.fromhex


def hx(b: bytes) -> str:
    return b.hex()


def aead_seal(key: bytes, nonce: bytes, aad: bytes, pt: bytes):
    """ChaCha20-Poly1305 → (ciphertext, tag16), matching CryptoKit ChaChaPoly."""
    out = ChaCha20Poly1305(key).encrypt(nonce, pt, aad if aad else None)
    return out[:-16], out[-16:]


def hkdf_sha256(secret: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length,
                salt=salt, info=info).derive(secret)


# ─────────────────────────────────────────────────────────────────────────
# RFC ground-truth self-checks (abort before emitting if pyca disagrees)
# ─────────────────────────────────────────────────────────────────────────

def rfc8439_vector():
    """RFC 8439 §2.8.2 ChaCha20-Poly1305 AEAD test vector."""
    key = H("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    nonce = H("070000004041424344454647")
    aad = H("50515253c0c1c2c3c4c5c6c7")
    pt = H("4c616469657320616e642047656e746c656d656e206f662074686520636c6173"
           "73206f66202739393a204966204920636f756c64206f6666657220796f75206f"
           "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73"
           "637265656e20776f756c642062652069742e")
    ct = H("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
           "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
           "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
           "3ff4def08e4b7a9de576d26586cec64b6116")
    tag = H("1ae10b594f09e26a7e902ecbd0600691")
    got_ct, got_tag = aead_seal(key, nonce, aad, pt)
    assert got_ct == ct and got_tag == tag, "RFC 8439 §2.8.2 self-check FAILED"
    return dict(rfc="RFC 8439 §2.8.2", key=hx(key), nonce=hx(nonce), aad=hx(aad),
                plaintext=hx(pt), ciphertext=hx(ct), tag=hx(tag))


def rfc5869_vector():
    """RFC 5869 Appendix A.1 Test Case 1 — HKDF-SHA256."""
    ikm = H("0b" * 22)
    salt = H("000102030405060708090a0b0c")
    info = H("f0f1f2f3f4f5f6f7f8f9")
    length = 42
    okm = H("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
            "34007208d5b887185865")
    got = hkdf_sha256(ikm, salt, info, length)
    assert got == okm, "RFC 5869 TC1 self-check FAILED"
    return dict(rfc="RFC 5869 A.1 TC1", ikm=hx(ikm), salt=hx(salt), info=hx(info),
                length=length, okm=hx(okm))


# ─────────────────────────────────────────────────────────────────────────
# Beacon PTT design vectors
# ─────────────────────────────────────────────────────────────────────────

# FIXED test session secret (production S is random per session). Deterministic
# so the vectors are stable and committable.
S = hashlib.sha256(b"aeronyra.ptt.kat.session-secret.v1").digest()

INFO_SEND = b"aeronyra.ptt.v1|initiator->responder"
INFO_RECV = b"aeronyra.ptt.v1|responder->initiator"

# A representative "voice frame" plaintext (fixed, ~Opus 24 kbps / 20 ms size).
VOICE = hashlib.sha512(b"aeronyra.ptt.kat.voice-frame.v1").digest()[:60]


def nonce_for(counter: int) -> bytes:
    """0x00000000 ‖ BE64(counter) — the pinned 12-byte nonce encoding."""
    return b"\x00\x00\x00\x00" + struct.pack(">Q", counter)


def be64(v: int) -> bytes:
    return struct.pack(">Q", v)


def hkdf_vectors():
    k_send = hkdf_sha256(S, b"", INFO_SEND)
    k_recv = hkdf_sha256(S, b"", INFO_RECV)
    return dict(
        session_secret=hx(S),
        salt="",  # empty
        k_send=dict(info_ascii=INFO_SEND.decode(), info_hex=hx(INFO_SEND),
                    derived_key=hx(k_send)),
        k_recv=dict(info_ascii=INFO_RECV.decode(), info_hex=hx(INFO_RECV),
                    derived_key=hx(k_recv)),
    ), k_send, k_recv


def aead_frame_vectors(k_send: bytes, k_recv: bytes):
    C40 = 2 ** 40
    # (name, key, direction, counter, aad_bytes, plaintext)
    cases = [
        ("empty_pt_no_aad",      k_send, "send", 0,   b"",        b""),
        ("voice_with_aad_c0",    k_send, "send", 0,   be64(0),    VOICE),
        ("voice_with_aad_c2p40", k_send, "send", C40, be64(C40),  VOICE),
        ("voice_no_aad_c7",      k_send, "send", 7,   b"",        VOICE),
        ("voice_recv_dir_c1",    k_recv, "recv", 1,   be64(1),    VOICE),
    ]
    out = []
    for name, key, direction, counter, aad, pt in cases:
        nonce = nonce_for(counter)
        ct, tag = aead_seal(key, nonce, aad, pt)
        out.append(dict(name=name, direction=direction, key=hx(key),
                        counter=counter, nonce=hx(nonce), aad=hx(aad),
                        plaintext=hx(pt), ciphertext=hx(ct), tag=hx(tag)))
    return out


def main():
    rfc8439 = rfc8439_vector()
    rfc5869 = rfc5869_vector()
    print("RFC self-check: RFC 8439 §2.8.2 AEAD  ... PASS")
    print("RFC self-check: RFC 5869 A.1 TC1 HKDF ... PASS")

    hkdf, k_send, k_recv = hkdf_vectors()
    frames = aead_frame_vectors(k_send, k_recv)

    doc = {
        "meta": {
            "purpose": "PTT session-crypto KAT — single reference vectors.",
            "generator": "tools/ptt_kat_gen.py (pyca/cryptography, OpenSSL)",
            "aead": "ChaCha20-Poly1305 (IETF, RFC 8439)",
            "kdf": "HKDF-SHA256 (RFC 5869)",
            "nonce_encoding": "0x00000000 || BE64(counter)  (12 bytes)",
            "note": "Swift/CryptoKit must reproduce these bytes exactly.",
        },
        "rfc8439_aead": rfc8439,
        "rfc5869_hkdf": rfc5869,
        "hkdf": hkdf,
        "aead_frames": frames,
    }

    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, os.pardir, "BeaconTests", "Fixtures")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "ptt_kat_vectors.json")
    with open(out_path, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=False)
        f.write("\n")
    print(f"\nwrote {os.path.relpath(out_path, os.path.join(here, os.pardir))}")
    return doc


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"ABORT: {e}", file=sys.stderr)
        sys.exit(1)
