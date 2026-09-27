#!/usr/bin/env python3
"""
gen_envelope_seal_kat.py — known-answer vectors for EnvelopeSeal v1.

STDLIB ONLY: X25519 (RFC 7748), HKDF-SHA256 (RFC 5869) and ChaCha20-Poly1305
(RFC 8439) are implemented here from the RFCs, independent of CryptoKit, and
checked against each RFC's own test vectors BEFORE any vector is emitted.

EnvelopeSeal v1 (must match Security/Session/EnvelopeSeal.swift):
  sealed = 0x01 || eph_pub(32) || ChaCha20-Poly1305(key, nonce, inner, aad)   (ct || tag16)
  shared = X25519(eph_priv, recipient_pub)          all-zero -> reject
  key(32) || nonce(12) = HKDF-SHA256(ikm = shared, salt = "" ,
                                     info = LABEL || 0x01 || eph_pub || recipient_pub, L = 44)
  aad    = 0x01 || eph_pub
  LABEL  = b"AeroNyra/envelope-seal/v1"

Usage: python3 tools/gen_envelope_seal_kat.py > BeaconTests/EnvelopeSealKATVectors.swift
"""
import hashlib, hmac, sys

# ---------------------------------------------------------------- X25519 (RFC 7748)
P = 2**255 - 19
A24 = 121665

def _decode_u(u):
    b = bytearray(u); b[31] &= 127
    return int.from_bytes(b, "little")

def _decode_scalar(k):
    b = bytearray(k); b[0] &= 248; b[31] &= 127; b[31] |= 64
    return int.from_bytes(b, "little")

def x25519(k, u):
    k = _decode_scalar(k); x1 = _decode_u(u)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        kt = (k >> t) & 1
        swap ^= kt
        if swap: x2, x3 = x3, x2; z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % P; AA = A * A % P
        B = (x2 - z2) % P; BB = B * B % P
        E = (AA - BB) % P
        C = (x3 + z3) % P; D = (x3 - z3) % P
        DA = D * A % P; CB = C * B % P
        x3 = (DA + CB) ** 2 % P
        z3 = x1 * (DA - CB) ** 2 % P
        x2 = AA * BB % P
        z2 = E * (AA + A24 * E) % P
    if swap: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")

def x25519_pub(k):
    return x25519(k, (9).to_bytes(32, "little"))

# ---------------------------------------------------------------- HKDF-SHA256 (RFC 5869)
def hkdf_sha256(ikm, salt, info, length):
    if not salt: salt = b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t; i += 1
    return okm[:length]

# ---------------------------------------------------------------- ChaCha20-Poly1305 (RFC 8439)
def _rotl(v, c): return ((v << c) & 0xffffffff) | (v >> (32 - c))

def _qr(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & 0xffffffff; s[d] = _rotl(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & 0xffffffff; s[b] = _rotl(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & 0xffffffff; s[d] = _rotl(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & 0xffffffff; s[b] = _rotl(s[b] ^ s[c], 7)

def chacha20_block(key, counter, nonce):
    const = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
    k = [int.from_bytes(key[i:i+4], "little") for i in range(0, 32, 4)]
    n = [int.from_bytes(nonce[i:i+4], "little") for i in range(0, 12, 4)]
    init = const + k + [counter] + n
    s = init[:]
    for _ in range(10):
        _qr(s, 0, 4, 8, 12); _qr(s, 1, 5, 9, 13); _qr(s, 2, 6, 10, 14); _qr(s, 3, 7, 11, 15)
        _qr(s, 0, 5, 10, 15); _qr(s, 1, 6, 11, 12); _qr(s, 2, 7, 8, 13); _qr(s, 3, 4, 9, 14)
    return b"".join(((s[i] + init[i]) & 0xffffffff).to_bytes(4, "little") for i in range(16))

def chacha20(key, counter, nonce, data):
    out = bytearray()
    for j in range(0, len(data), 64):
        ks = chacha20_block(key, counter + j // 64, nonce)
        out += bytes(a ^ b for a, b in zip(data[j:j+64], ks))
    return bytes(out)

def poly1305(key, msg):
    r = int.from_bytes(key[:16], "little") & 0x0ffffffc0ffffffc0ffffffc0fffffff
    s = int.from_bytes(key[16:], "little")
    p, acc = (1 << 130) - 5, 0
    for i in range(0, len(msg), 16):
        n = int.from_bytes(msg[i:i+16] + b"\x01", "little")
        acc = (acc + n) * r % p
    return ((acc + s) & ((1 << 128) - 1)).to_bytes(16, "little")

def _pad16(x): return b"\x00" * ((16 - len(x) % 16) % 16)

def aead_seal(key, nonce, pt, aad):
    otk = chacha20_block(key, 0, nonce)[:32]
    ct = chacha20(key, 1, nonce, pt)
    mac = aad + _pad16(aad) + ct + _pad16(ct) + len(aad).to_bytes(8, "little") + len(ct).to_bytes(8, "little")
    return ct, poly1305(otk, mac)

# ---------------------------------------------------------------- self-check against the RFCs
def h(s): return bytes.fromhex(s.replace(" ", "").replace("\n", ""))

def self_check():
    # RFC 7748 §5.2, first test vector.
    assert x25519(h("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                  h("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")) == \
        h("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
    # RFC 7748 §6.1 Diffie-Hellman.
    a = h("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    b = h("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    assert x25519_pub(a) == h("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    assert x25519_pub(b) == h("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    shared = h("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    assert x25519(a, x25519_pub(b)) == shared and x25519(b, x25519_pub(a)) == shared
    # RFC 5869 A.1 (basic SHA-256) and A.3 (zero-length salt and info).
    ikm = h("0b" * 22)
    assert hkdf_sha256(ikm, h("000102030405060708090a0b0c"), h("f0f1f2f3f4f5f6f7f8f9"), 42) == h(
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    assert hkdf_sha256(ikm, b"", b"", 42) == h(
        "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    # RFC 8439 §2.8.2 AEAD.
    pt = (b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip "
          b"for the future, sunscreen would be it.")
    ct, tag = aead_seal(h("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
                        h("070000004041424344454647"), pt, h("50515253c0c1c2c3c4c5c6c7"))
    assert ct == h("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca967128"
                   "2fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fa"
                   "b324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116")
    assert tag == h("1ae10b594f09e26a7e902ecbd0600691")

# ---------------------------------------------------------------- EnvelopeSeal v1
LABEL = b"AeroNyra/envelope-seal/v1"
VERSION = b"\x01"

def seal(inner, recipient_pub, eph_priv):
    eph_pub = x25519_pub(eph_priv)
    shared = x25519(eph_priv, recipient_pub)
    assert shared != b"\x00" * 32
    okm = hkdf_sha256(shared, b"", LABEL + VERSION + eph_pub + recipient_pub, 44)
    ct, tag = aead_seal(okm[:32], okm[32:], inner, VERSION + eph_pub)
    return VERSION + eph_pub + ct + tag

def main():
    self_check()
    vectors = []
    for i, n in enumerate([0, 1, 33, 64, 300]):
        r_priv = hashlib.sha256(b"envelope-seal-kat/recipient/%d" % i).digest()
        e_priv = hashlib.sha256(b"envelope-seal-kat/ephemeral/%d" % i).digest()
        inner = hashlib.shake_256(b"envelope-seal-kat/inner/%d" % i).digest(n) if n else b""
        r_pub = x25519_pub(r_priv)
        vectors.append((r_priv, r_pub, e_priv, x25519_pub(e_priv), inner, seal(inner, r_pub, e_priv)))
    out = sys.stdout
    out.write("// EnvelopeSealKATVectors.swift — GENERATED by tools/gen_envelope_seal_kat.py.\n")
    out.write("// DO NOT EDIT. Independent pure-Python X25519 / HKDF-SHA256 / ChaCha20-Poly1305,\n")
    out.write("// self-checked against RFC 7748 §5.2 + §6.1, RFC 5869 A.1 + A.3, RFC 8439 §2.8.2.\n\n")
    out.write("import Foundation\n\nenum EnvelopeSealKATVectors {\n")
    out.write("    struct Vector {\n        let recipientPrivate: String\n        let recipientPublic: String\n"
              "        let ephemeralPrivate: String\n        let ephemeralPublic: String\n"
              "        let inner: String\n        let sealed: String\n    }\n\n    static let all: [Vector] = [\n")
    for v in vectors:
        out.write("        Vector(\n")
        for name, val in zip(["recipientPrivate", "recipientPublic", "ephemeralPrivate",
                              "ephemeralPublic", "inner", "sealed"], v):
            out.write(f'            {name}: "{val.hex()}"{"," if name != "sealed" else ""}\n')
        out.write("        ),\n")
    out.write("    ]\n}\n")

if __name__ == "__main__":
    main()
