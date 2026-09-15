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

biber is a Perl program. The binary carries the Perl interpreter, biber itself
and all of the roughly 100 modules it uses, compiled ones included, so it needs
no Perl installation and reads nothing from disk except your own files.

- Remote data sources work over `http://` but not `https://`: the TLS module
  (`Net::SSLeay`) is not included. Local `.bib` and BibLaTeXML files are
  unaffected.
- The build runs biber's own test documents through the binary and checks that
  every `.bbl` matches the one the reference biber produces.
