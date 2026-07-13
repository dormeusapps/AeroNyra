# Vendored Opus — provenance & verification

Beacon vendors the Xiph.Org **Opus 1.5.2** codec for 1:1 sealed push-to-talk
voice. This mirrors the pinned-source posture used for LibSignalClient (git tag
+ FFI checksum) and WebRTC-lib (exact version + spec checksum): the dependency
is pinned to a **reputable upstream release** whose integrity is **verified by
checksum**, not a third-party CocoaPods vendoring.

## Source

- Release: `opus-1.5.2.tar.gz`
- URL: https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
- License: BSD-3-Clause (`COPYING`)

## Verification (SHA-256)

Computed locally and compared to Xiph's published `SHA256SUMS`
(https://downloads.xiph.org/releases/opus/SHA256SUMS.txt) — **they match**:

```
65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1  opus-1.5.2.tar.gz
```

Re-verify:

```sh
curl -sSLO https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
shasum -a 256 opus-1.5.2.tar.gz   # must equal the hash above
```

## What is vendored

The `celt/`, `silk/`, `src/`, and `include/` directories plus `COPYING` and
`AUTHORS` are **verbatim** from the verified tarball (re-verify by extracting the
tarball and diffing those directories — the diff must be empty). Exactly **two**
files here are NOT from the tarball:

- `config.h` — stands in for the autotools-generated config so the sources build
  under CocoaPods; selects the float build, portable C (no SIMD), C99 VLA stack.
- `beacon_opus_ctl.h` — `static inline` shims over Opus's variadic
  `opus_encoder_ctl` (which Swift cannot call directly). Thin, no behavior.

**Not vendored** (not needed for standard VOIP encode/decode with inband FEC +
standard PLC, and not compiled): `dnn/` (deep-PLC/DRED neural extensions, ~17 MB),
`tests/`, `doc/`, and the autotools/CMake/Meson build system.

## What is compiled

`Opus.podspec` compiles the generic-C **float** build, mirroring upstream's
`celt_sources.mk` / `silk_sources.mk` / `opus_sources.mk` (`CELT_SOURCES`,
`SILK_SOURCES` + `SILK_SOURCES_FLOAT`, `OPUS_SOURCES` + `OPUS_SOURCES_FLOAT`).
No SIMD, no runtime CPU detection. The four upstream demo/CLI programs
(`opus_custom_demo.c`, `opus_demo.c`, `opus_compare.c`, `repacketizer_demo.c`)
are excluded.
