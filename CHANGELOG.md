# Changelog

## [Unreleased]

### Fixed

- On 32-bit Linux (i686 and armv7l), entries whose dates lie very far in the
  future, such as the year 17000002, were silently left out of the `.bbl`.
  Every released i686 and armv7l binary is affected. Those binaries now use
  64-bit integers and produce the same bibliography as the other platforms.

- The Linux binaries for armv7l, riscv64 and ppc64le work again. Every build
  of them since the toolchain change crashed on start, even on `--version`.
  No release shipped with this.
