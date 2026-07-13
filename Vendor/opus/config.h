/* config.h — Beacon's build configuration for the vendored Xiph Opus 1.5.2.
 *
 * This is the ONLY file under Vendor/opus/ that is NOT verbatim from the
 * upstream tarball — it stands in for the autotools-generated config.h so the
 * sources compile under CocoaPods without running ./configure. It selects:
 *   • the FLOAT build (FIXED_POINT intentionally undefined),
 *   • portable C only — no SIMD and no runtime CPU detection
 *     (OPUS_HAVE_RTCD / OPUS_ARM_ / OPUS_X86_ left undefined; the podspec
 *      compiles only the generic C sources, never the arm or x86 subdirs of
 *      celt and silk),
 *   • C99 variable-length arrays for Opus's temporary stack allocations.
 * Everything else is left to Opus's own portable fallbacks.
 */
#ifndef BEACON_OPUS_CONFIG_H
#define BEACON_OPUS_CONFIG_H

#define OPUS_BUILD 1
#define PACKAGE_VERSION "1.5.2"

/* Temporary-allocation mode (celt/stack_alloc.h requires exactly one). */
#define VAR_ARRAYS 1

/* iOS libm provides these; lets Opus use the fast rounding path. */
#define HAVE_LRINT 1
#define HAVE_LRINTF 1

#endif /* BEACON_OPUS_CONFIG_H */
