# biber

[biber](https://github.com/plk/biber) — the backend processor for [biblatex](https://ctan.org/pkg/biblatex). A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/biber/actions/workflows/biber.yml/badge.svg)](https://github.com/unpins/biber/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install biber`.

## Usage

Run `biber` with [unpin](https://github.com/unpins/unpin):

```bash
unpin biber --version
unpin biber mydocument
```

To install it onto your PATH:

```bash
unpin install biber
```

## Man pages

`biber.1` is embedded in the binary — read it with `unpin man biber`.

## Build locally

```bash
nix build github:unpins/biber
./result/bin/biber --version
```

Or run directly:

```bash
nix run github:unpins/biber -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/biber/releases) page has standalone binaries for manual download.

## Build notes

biber is a Perl program built from ~100 modules, ~20 of them compiled (XS). A
single static binary has no dynamic loader, so each XS module is linked in as a
**static extension** instead of loaded as a `.so` at runtime. The whole module
tree (the pure-Perl dependencies, the XS modules' `.pm`, and biber's own library)
is packed into the executable as a ZIP and served by a linker-level VFS — `open`/
`stat` are intercepted at link time so `@INC` reads straight from the embedded
blob, with no companion module tree on disk.

- The four XS modules that carry an external C library are folded in statically
  too: `Text::BibTeX` (bundled btparse), `Unicode::LineBreak` (bundled sombok),
  `XML::LibXML` (libxml2) and `XML::LibXSLT` (libxslt/libexslt).
- The only XS module left out is `Net::SSLeay`, used for `https` remote
  datasources — biber runs fully offline without it.
