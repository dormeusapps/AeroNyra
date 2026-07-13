Pod::Spec.new do |s|
  s.name         = 'Opus'
  s.version      = '1.5.2'
  s.summary      = 'Xiph.Org Opus audio codec — vendored from the verified upstream release.'
  s.description  = <<-DESC
    The Opus interactive audio codec (RFC 6716), vendored verbatim from the
    official Xiph release opus-1.5.2.tar.gz (SHA-256 verified against Xiph's
    published SHA256SUMS — see VENDORING.md). Float build, portable C only (no
    SIMD, no runtime CPU detection). BSD-3-Clause (see COPYING). Used by Beacon
    only for 1:1 sealed push-to-talk voice; the deep-PLC/DRED neural extensions
    (dnn/) are neither vendored nor compiled.
  DESC
  s.homepage     = 'https://opus-codec.org'
  s.license      = { :type => 'BSD-3-Clause', :file => 'COPYING' }
  s.author       = 'Xiph.Org Foundation'
  # Provenance only — a :path pod builds from the local files below, this URL is
  # not fetched. It records exactly where the vendored source came from.
  s.source       = { :http => 'https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz',
                     :sha256 => '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1' }

  s.platform     = :ios, '17.0'
  s.requires_arc = false

  # Compile the generic-C FLOAT build, mirroring upstream's *_sources.mk:
  #   CELT_SOURCES, SILK_SOURCES + SILK_SOURCES_FLOAT, OPUS_SOURCES + _FLOAT.
  # The non-recursive globs deliberately skip celt/arm, celt/x86, silk/fixed,
  # and every */arm、*/x86 subdir, so no SIMD is built.
  s.source_files =
    'config.h',
    'beacon_opus_ctl.h',
    'include/*.h',
    'celt/*.{c,h}',
    'silk/*.{c,h}',
    'silk/float/*.{c,h}',
    'src/*.{c,h}'

  # Upstream demo/CLI programs (each has its own main()) — never compiled.
  s.exclude_files =
    'celt/opus_custom_demo.c',
    'src/opus_demo.c',
    'src/opus_compare.c',
    'src/repacketizer_demo.c'

  s.public_header_files = 'include/*.h', 'beacon_opus_ctl.h'
  s.preserve_paths = 'COPYING', 'AUTHORS'

  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => 'HAVE_CONFIG_H=1',
    'HEADER_SEARCH_PATHS' =>
      '"${PODS_TARGET_SRCROOT}" ' \
      '"${PODS_TARGET_SRCROOT}/include" ' \
      '"${PODS_TARGET_SRCROOT}/celt" ' \
      '"${PODS_TARGET_SRCROOT}/silk" ' \
      '"${PODS_TARGET_SRCROOT}/silk/float"',
    # Vendored third-party C — don't fail Beacon's build on upstream warnings.
    'GCC_TREAT_WARNINGS_AS_ERRORS' => 'NO',
    'WARNING_CFLAGS' => '-w'
  }
end
