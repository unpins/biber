# Changelog

## [Unreleased]

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 14% smaller (34.7 MB to 29.9 MB); upstream's ten control
  bibliographies (`full-bbl`, `general`, `names`, `sort-complex`, `translit`,
  `biblatexml`, `dateformats`, `uniqueness1`, `labelalpha` and
  `sections-complex`) were run through it under Wine and each `.bbl` came out
  byte for byte what the previous binary produced.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.

### Fixed

- On 32-bit Linux (i686 and armv7l), entries whose dates lie very far in the
  future, such as the year 17000002, were silently left out of the `.bbl`.
  Every released i686 and armv7l binary is affected. Those binaries now use
  64-bit integers and produce the same bibliography as the other platforms.

- The Linux binaries for armv7l, riscv64 and ppc64le work again. Every build
  of them since the toolchain change crashed on start, even on `--version`.
  No release shipped with this.
