# Changelog

## [Unreleased]

### Fixed

- Remote data sources over `https://` work. They failed with `Can't load module
  Net::SSLeay`: the TLS module was not in the binary.

- On Windows, `--input-encoding` and `--output-encoding` accepted only UTF-8,
  UTF-16/32, ASCII, Latin-1 and cp1252; any other encoding (`latin2`, `koi8-r`,
  `shiftjis`, …) failed with `Unknown encoding`. The binary grows from 29.9 MB
  to 34.6 MB with the encoding tables.
- On Windows, the embedded perl's `Errno` knew none of the standard error codes
  (`ENOENT`, `EINTR`, …), and `Socket` was missing.
- On Windows, the embedded perl's `HTTP::Tiny` and `Compress::Raw::*` are now
  the versions nixpkgs carries for security fixes, as on Linux and macOS
  (`HTTP::Tiny` 0.094, `Compress::Raw::Zlib` 2.222), not the older ones bundled
  with perl.

## [2.21-4] - 2026-09-26

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
