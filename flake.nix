{
  description = "biber (the biblatex backend) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # biber (the biblatex backend) as ONE self-contained binary. biber is a
  # heavily-XS Perl program: ~20 compiled (XS) modules plus ~86 pure-Perl ones.
  # A single static binary is `-Uusedl` (no DynaLoader), so the XS can't be
  # loaded as .so at runtime -- instead each is built as a *static extension*
  # linked into the interpreter (the same mechanism perl's own core XS use:
  # ExtUtils::Miniperl::writemain regenerates perlmain.c, the .a's are folded in).
  # The whole @INC (pure-Perl deps + the XS modules' .pm + biber's own lib) is
  # packed into the executable's single EOF ZIP (withUnpinEmbed; zstd method 93,
  # shared dict) and served by a linker-level VFS: open/stat are intercepted
  # (Linux `-Wl,--wrap`) and any `/zip/...` path is read back from the running
  # binary by the shared unpin-vfs core in self-EOF mode (-DUNPIN_VFS_SELF), so
  # there is no companion module tree on disk and no blob object/relink. The
  # binary runs biber directly (main injects the embedded /zip/bin/biber driver).
  #
  # The four XS that carry an external C library are linked statically too:
  # Text::BibTeX (bundled btparse), Unicode::LineBreak (bundled sombok),
  # XML::LibXML (system libxml2), XML::LibXSLT (system libxslt/libexslt). The
  # only XS left out is Net::SSLeay (https remote datasources) -- biber runs
  # fully offline without it.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      mk = pkgs:
        let
          sp = pkgs.pkgsStatic;
          lib = pkgs.lib;
          # The static perl. The ext/re static extension re-emits regexp-aux
          # symbols (Perl_set_ANYOF_arg, …) already in libperl.a; native musl-ld
          # silently dedups, but the cross ld.bfd (riscv64/ppc64le/armv7l,
          # binutils 2.46) treats it as a fatal multiple-definition. The patch
          # fires -DPERL_EXT_RE_STATIC whenever usedl is undef (always true for
          # this -Uusedl perl), suppressing the duplicate at the source. Benign
          # for the arches that linked before.
          host = sp.stdenv.hostPlatform;
          isDarwin = host.isDarwin or false;
          prefix = sp.stdenv.cc.targetPrefix;
          perl = sp.perl.overrideAttrs (old:
          let
            # nixpkgs' interpreter.nix bakes an absolute `${coreutils}/bin/pwd`
            # into Cwd.pm on EVERY cross (native uses `$(type -P pwd)`), making
            # coreutils -- and thus gmp -- a build input of perl. On the darwin
            # (aarch64<->x86_64) cross the engine builds that gmp, whose hand-asm
            # ld64.lld rejects ("BRANCH relocation width 1 must be 4"). Rewrite to
            # the native form; replaceStrings drops the text but keeps the string
            # context, so also discard it to actually cut the coreutils edge
            # (verified the sole context element of the cross postPatch). Native
            # path unchanged.
            crossBasePostPatch =
              let b = old.postPatch or ""; in
              if crossCompiling
              then builtins.unsafeDiscardStringContext (builtins.replaceStrings
                [ "'${sp.coreutils}/bin/pwd'" ] [ ''"$(type -P pwd)"'' ] b)
              else b;
          in {
            # On a case-insensitive FS (the darwin<->darwin cross) perl-cross's
            # configure clobbers perl's Configure, so nixpkgs' no-sys-dirs.patch
            # (which patches Configure) can't apply -- and is moot there (the
            # cross uses perl-cross's own configure). Drop it for the darwin cross.
            patches = (
              let base = old.patches or [ ];
              in if crossCompiling && isDarwin
              then builtins.filter (p: !(lib.hasInfix "no-sys-dirs" (toString p))) base
              else base
            ) ++ [ ./patches/ext-re-static-aux.patch ];
            # darwin: pkgsStatic.perl's libperl.a rule dies "Error 127" (ranlib
            # not found) and installperl runs install_name_tool because it tests
            # $Config{useshrplib} (the string 'false', truthy in perl). Same two
            # fixes unpins/perl applies for darwin: supply a real ranlib and
            # require the value to be the string "true".
            configureFlags = (old.configureFlags or [ ])
              # Engine: perl's Configure nm-scans stdenv.cc.libc's archive for libc
              # symbols, but that is null under the engine (musl is served from
              # clang's on-demand sysroot) -> it loops on "Where is your C library?".
              # -Dusenm=false takes the compile-test fallback instead. Cross uses
              # perl-cross, which never runs this scan.
              ++ lib.optional (!crossCompiling) "-Dusenm=false"
              # Engine: Configure probes header PRESENCE with `test -f`, but the
              # engine cc reports its musl headers under the virtual clang-VFS
              # sysroot (not real files) so every musl header comes back absent.
              # Hand it a real musl of the same ABI to detect against.
              ++ engineIncFix
              ++ lib.optionals isDarwin [
                "-Dranlib=${prefix}ranlib"
                # Engine on darwin: Configure's gccversion detection misfires so it
                # never injects -fno-strict-aliasing and the darwin hints force -O3;
                # perl's SV/magic type-punning then miscompiles ("panic:
                # magic_killbackrefs" loading warnings.pm). Force them explicitly.
                "-Accflags=-fno-strict-aliasing"
                "-Accflags=-fwrapv"
              ];
            preConfigure = (old.preConfigure or "")
              # Engine cross: perl-cross probes the ELF build host for readelf/
              # objdump, but the engine toolchain ships only the `llvm` multitool.
              # Point the env knobs at `llvm readelf/objdump` via bcIntrospect
              # (which lowers the bitcode objects perl-cross feeds them). Linux only
              # (the darwin cross rewrites these probes via cross_darwin.pl below).
              + lib.optionalString (crossCompiling && !isDarwin) ''
                export READELF="${bcIntrospect} readelf"
                export OBJDUMP="${bcIntrospect} objdump"
              ''
              # Engine darwin cross: -Accflags reaches only the TARGET perl. perl-
              # cross builds the build-time miniperl in a separate `--mode=buildmini`
              # respawn that takes ccflags from $HOSTCFLAGS (empty), so miniperl
              # compiles WITHOUT -fno-strict-aliasing and segfaults on the same
              # miscompile. Feed the flags via HOSTCFLAGS too.
              + lib.optionalString (crossCompiling && isDarwin) ''
                export HOSTCFLAGS="-fno-strict-aliasing -fwrapv"
              '';
            postPatch = crossBasePostPatch
              + lib.optionalString isDarwin ''
                substituteInPlace installperl \
                  --replace-fail '&& $Config{useshrplib}' '&& $Config{useshrplib} eq "true"'
              ''
              # perl-cross has no darwin support and assumes an ELF build host
              # (readelf/objdump); on a darwin build host (the darwin<->darwin
              # cross) rewrite those probes to compile-only, cross-safe forms.
              + lib.optionalString (crossCompiling && isDarwin) ''
                ${bperl} ${./src/cross_darwin.pl}
              ''
              # Engine native: the engine cc emits musl headers under the virtual
              # clang-VFS sysroot /__unpin_ziglib__/...; perl's makedepend records
              # them as prerequisites and make dies "No rule to make target
              # .../alloca.h". Drop them in makedepend_file.SH's line-marker sed.
              + lib.optionalString (!crossCompiling) ''
                substituteInPlace makedepend_file.SH --replace-fail \
                  ${lib.escapeShellArg "-e '/^#.*<built-in>/d' \\"} \
                  ${lib.escapeShellArg "-e '/^#.*<built-in>/d' -e '\\#/__unpin_ziglib__#d' \\"}
              ''
              # Engine cross: Errno.pm's generator scans errno.h AS A FILE to harvest
              # E* macro names, but the engine's musl headers are virtual -> "No error
              # definitions found". Short-circuit get_files to a stub TU the engine cc
              # expands (`clang -E -dM` over `#include <errno.h>`). Linux cross only
              # (native finds errno.h via engineIncFix's locincpth).
              + lib.optionalString (crossCompiling && !isDarwin) ''
                substituteInPlace ext/Errno/Errno_pm.PL --replace-fail \
                  'sub get_files {' \
                  'sub get_files { if (open(my $s, ">", "unpin_errno.c")) { print $s "#include <errno.h>\n"; close $s; return ("unpin_errno.c"); }'
              '';
            # perl-cross (the true-cross path) builds each static XS .a but its
            # `static_modules` recipe never runs pm_to_blib, so the modules' .pm
            # (Cwd.pm, List/Util.pm, Storable.pm, …) never reach the install tree
            # -> `use Cwd` fails at runtime. Patch the Makefile's static rule to
            # also stage the .pm. Native builds install them normally; no-op there.
            postConfigure = (old.postConfigure or "")
              + lib.optionalString crossCompiling ''
                ${bperl} ${./src/cross_static_pm.pl} Makefile
              '';
          });
          # --- platform knobs (mirror the proven spike playground/biber) ---
          # darwin has no musl off64 hack. crypt.h / libcrypt / libiconv aren't on
          # darwin's default paths but perl's recorded ccflags/ldopts reference them.
          # (The VFS bind is IR symbol rewrite for every platform now -- no per-OS
          # objcopy/--wrap knobs; the 32-bit _REDIR_TIME64 stat rename is an IR sed.)
          lfs = if isDarwin then "" else "-D_LARGEFILE64_SOURCE";
          cryptInc = if isDarwin then "-I${lib.getDev sp.libxcrypt}/include" else "";
          # libxml2's encoding.c (xmlIconvConvert) references plain iconv/iconv_open/
          # iconv_close. On darwin the STATIC libiconv archive (Apple's libiconv-113,
          # which exports those PLAIN names -- not GNU's renamed libiconv_*) lives in
          # the `dev` output, NOT in `getLib` (that is only the iconv CLI: bin/share).
          # Reference the archive directly so the static plain-iconv symbols resolve.
          # Under the engine the LTO link retains xmlIconvConvert (reachable from the
          # encoding-handler table); pre-engine's non-LTO --gc-sections dropped it, so
          # this latent -L-points-at-nothing bug only surfaced under the engine.
          cryptLib = if isDarwin
            then "-L${lib.getLib sp.libxcrypt}/lib ${lib.getDev sp.libiconv}/lib/libiconv.a"
            else "";
          # When the build host can't run the target binary (ppc64le/riscv64/
          # armv7l, windows), the codegen perl can't be the target perl. Drive
          # the Perl-side steps (Makefile.PL, xsubpp, writemain, ldopts, Config
          # queries) with the build-host perl pointed at the target archlib:
          # Config_heavy.pl is plain data and both are perl 5.42.0, so MakeMaker
          # emits a Makefile with the target cc/ccflags/CORE while codegen
          # (Config-free) runs on the host; the C is compiled by the cross $CC.
          # This is how nixpkgs/perl-cross cross-builds native modules.
          crossCompiling = !(sp.stdenv.buildPlatform.canExecute host);
          bperl = "${pkgs.buildPackages.perl}/bin/perl";
          pp = sp.perlPackages;
          # The biber driver script + the @INC module trees it `use lib`s are
          # pure-Perl / arch-independent .pm (the compiled XS we build by hand).
          # Take them from the BUILD-host biber so cross targets don't drag the
          # whole biber Perl closure through a (failing) cross compile. For native
          # x86_64 buildPackages.biber IS pkgs.biber, so this is a no-op there.
          biber = pkgs.buildPackages.biber;

          # ---- unpin-llvm engine plumbing (mirrors unpins/perl's mk) ----
          # Under the engine sp=pkgs.pkgsStatic is the bitcode set, so every object
          # (perl, the 19 XS, libxml2/libxslt) is LLVM bitcode and the binary is
          # LTO-linked. perl's Configure / perl-cross introspect real headers and
          # objects, which the engine serves virtually / as bitcode -> the same
          # fixes unpins/perl applies. The VFS is bound by IR symbol rewrite in the
          # relink (below), not `ld --wrap` / `objcopy --redefine-sym` (neither can
          # touch a bitcode symtab).
          engineMultitool = "${ulib.unpinToolchain sp.stdenv.buildPlatform.system}/bin/llvm";
          # A real musl (same 1.2.x ABI) for perl's native Configure to scan: the
          # engine's own musl headers live inside the clang binary's VFS, invisible
          # to Configure's `test -f`. HOST platform, not build (an i686 target is
          # x86_64-runnable = native, but needs 32-bit headers). Linux native only.
          engineIncFix =
            if crossCompiling || isDarwin then [ ]
            else
              let musl = (import pkgs.path { inherit (host) system; })
                .pkgsStatic.stdenv.cc.libc;
              in [ "-Dlocincpth=${lib.getDev musl}/include" ];
          # perl-cross introspects target objects with readelf/objdump; under the
          # engine those are bitcode ("not supported"). Lower a bitcode arg to a
          # native ELF object for the triple embedded in the module before handing
          # it to the real llvm tool; ELF args pass through. -target is mandatory
          # (else clang lowers to the x86_64 host -> wrong sizes/endian). Cross only.
          bcIntrospect = pkgs.buildPackages.writeShellScript "unpin-biber-bc-introspect" ''
            mt=${engineMultitool}
            tool=$1; shift
            n=$#
            obj=''${!n}
            if [ -f "$obj" ] && [ "$(od -An -tx1 -N4 "$obj" 2>/dev/null | tr -d ' \n')" = 4243c0de ]; then
              triple=$("$mt" opt -S "$obj" -o - 2>/dev/null \
                | sed -n 's/^target triple = "\(.*\)"/\1/p' | head -1)
              low=$(mktemp -d)/lowered.o
              if [ -n "$triple" ] && "$mt" clang -target "$triple" -fno-lto -x ir -c "$obj" -o "$low" 2>/dev/null; then
                set -- "''${@:1:$((n - 1))}" "$low"
              fi
            fi
            exec "$mt" "$tool" "$@"
          '';

          # The 14 pure-XS (no external C library) modules of biber's closure.
          pureXs = {
            inherit (pp) DateSimple Clone EncodeHanExtra ReadonlyXS EncodeEUCJPASCII
                         EncodeJIS2K DateTime PerlIOutf8_strict SubIdentify SortKey
                         autovivification ListMoreUtilsXS TextCSV_XS HTMLParser;
          };
          pureXsList = lib.concatStringsSep "\n"
            (lib.mapAttrsToList (n: v: "${n} ${v.src}") pureXs);

          # The biber binary: 19 XS as static extensions + the @INC VFS blob.
          biberBin = sp.stdenv.mkDerivation {
            pname = "biber";
            version = biber.version or "2.21";
            dontUnpack = true;
            nativeBuildInputs = [ perl pkgs.buildPackages.perl pkgs.file ];
            buildInputs = [ sp.libxml2 sp.libxslt ];
            PURE_XS_LIST = pureXsList;
            TEXTBIBTEX_SRC = pp.TextBibTeX.src;
            XMLLIBXML_SRC = pp.XMLLibXML.src;
            XMLLIBXSLT_SRC = pp.XMLLibXSLT.src;
            LINEBREAK_SRC = pp.UnicodeLineBreak.src;
            PARAMSVALIDATE_SRC = pp.ParamsValidate.src;
            meta = (biber.meta or { }) // { mainProgram = "biber"; };

            buildPhase = ''
              runHook preBuild
              # off64_t/LFS64 for every external XS on static-musl perl (empty on
              # darwin); +crypt.h include there. UNPIN_VFS_OFF keeps the VFS
              # dormant for build-time perl runs (writemain etc.).
              export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} ${lfs} ${cryptInc}"
              export NIX_LDFLAGS="''${NIX_LDFLAGS:-} ${cryptLib}"
              export UNPIN_VFS_OFF=1
              ${if crossCompiling then ''
                # cross: target perl can't run here. Derive its archlib by glob and
                # drive codegen with the build-host perl pointed at the target
                # archlib (-I "$ARCHLIB"): Config_heavy.pl is plain data, and
                # archname-checking modules like Errno load from there and match the
                # target %Config. The one hazard is Cwd -- it's XS and the target's
                # is a static (-Uusedl) build whose XS can't load on the host, so
                # Cwd::getcwd falls back to pure-perl (fine on Linux) but returns
                # undef on a darwin build host -> MakeMaker dies "Can't figure out
                # your cwd". Shadow ONLY Cwd with the build-host's host-runnable
                # copy (it doesn't check archname), keeping the target archlib for
                # everything else.
                ARCHLIB="$(dirname "$(echo ${perl}/lib/perl5/*/*/CORE)")"
                BARCH_B="$(${bperl} -MConfig -e 'print $Config{archlibexp}')"
                mkdir -p "$NIX_BUILD_TOP/cwddir/auto"
                ln -sf "$BARCH_B/Cwd.pm" "$NIX_BUILD_TOP/cwddir/"
                ln -sf "$BARCH_B/auto/Cwd" "$NIX_BUILD_TOP/cwddir/auto/"
                PERL="${bperl} -I$NIX_BUILD_TOP/cwddir -I$ARCHLIB"
              '' else ''
                PERL=${perl}/bin/perl
                ARCHLIB="$($PERL -MConfig -e 'print $Config{archlibexp}')"
              ''}
              PRIVLIB="$($PERL -MConfig -e 'print $Config{privlibexp}')"
              CCFLAGS="$($PERL -MConfig -e 'print $Config{ccflags}')"
              XML2_CF="-I${sp.libxml2.dev}/include/libxml2"
              XSLT_CF="-I${sp.libxslt.dev}/include -DHAVE_EXSLT"
              XML2_A="${sp.libxml2.out}/lib/libxml2.a"
              XSLT_A="${sp.libxslt.out}/lib/libxslt.a"
              EXSLT_A="${sp.libxslt.out}/lib/libexslt.a"
              mkdir -p work && cd work
              ALLA=""; EXTS=""

              # ===== engine bitcode helpers =====
              # Under the engine every object is LLVM bitcode, so symbol edits
              # (the VFS bind + the utf8_strict weaken) go through the IR:
              # `llvm opt -S | sed | llvm opt`, not objcopy / ld --wrap.
              MT=${engineMultitool}
              isbc() { case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in 4243c0de|dec0170b) return 0;; *) return 1;; esac; }
              # Rename perl's libc file-op refs to the VFS shims. @sym is a FUNCTION
              # symbol (sigil differs from %struct.stat). darwin emits raw-label
              # imports (@"\01_stat$INODE64"); 32-bit musl renames stat->__stat_time64.
              # Rules that don't match a given IR are no-ops.
              vfsSed() {
                sed -i \
                  -e 's/@open\b/@unpinvfs_open/g' \
                  -e 's/@stat\b/@unpinvfs_stat/g' \
                  -e 's/@lstat\b/@unpinvfs_lstat/g' \
                  -e 's/@access\b/@unpinvfs_access/g' \
                  -e 's/@__stat_time64\b/@unpinvfs_stat/g' \
                  -e 's/@__lstat_time64\b/@unpinvfs_lstat/g' \
                  -e 's/@"\\01__stat_time64"/@unpinvfs_stat/g' \
                  -e 's/@"\\01__lstat_time64"/@unpinvfs_lstat/g' \
                  -e 's/@"\\01_open"/@unpinvfs_open/g' \
                  -e 's/@"\\01_access"/@unpinvfs_access/g' \
                  -e 's/@"\\01_stat\$INODE64"/@unpinvfs_stat/g' \
                  -e 's/@"\\01_lstat\$INODE64"/@unpinvfs_lstat/g' \
                  "$1"
              }
              bcrewrite() { $MT opt -S "$1" -o "$1.ll"; vfsSed "$1.ll"; $MT opt "$1.ll" -o "$1"; rm -f "$1.ll"; }
              # Rewrite every bitcode member of an archive in place, then repack with
              # the bitcode-aware llvm ar so the LTO link resolves from the index.
              bcrewriteArchive() {
                local a; a=$(readlink -f "$1"); local d; d=$(mktemp -d)
                ( cd "$d" && $MT ar x "$a" )
                for o in "$d"/*; do [ -f "$o" ] || continue; isbc "$o" && bcrewrite "$o"; done
                rm -f "$1" && $MT ar rcs "$1" "$d"/*
              }
              # Engine analogue of objcopy --weaken-symbol (llvm-objcopy can't edit a
              # bitcode symtab): prepend `weak` linkage to the matching `define`.
              weakenArchive() {  # $1 = archive, $2 = symbol
                local a; a=$(readlink -f "$1"); local d; d=$(mktemp -d)
                ( cd "$d" && $MT ar x "$a" )
                for o in "$d"/*; do
                  [ -f "$o" ] || continue; isbc "$o" || continue
                  $MT opt -S "$o" -o "$o.ll"
                  sed -i -E "/@$2\(/ s/^define /define weak /" "$o.ll"
                  $MT opt "$o.ll" -o "$o"; rm -f "$o.ll"
                done
                rm -f "$1" && $MT ar rcs "$1" "$d"/*
              }

              # ===== (1) the 14 pure-XS via the generic loop =====
              mkdir -p pure
              echo "$PURE_XS_LIST" | while read -r name src; do
                [ -z "$name" ] && continue
                mkdir -p "pure/$name" && tar xf "$src" -C "pure/$name" --strip-components=1
                ( cd "pure/$name"
                  # List::MoreUtils::XS probes the toolchain with Config::AutoConf
                  # (links loadable test modules -> fails under -Uusedl on some
                  # hosts). Drop in a captured LMUconfig.h and skip the probe.
                  if [ -f inc/Config/AutoConf/LMU.pm ]; then
                    cp ${./src/LMUconfig.h} LMUconfig.h
                    $PERL -i -pe 's/^inc::Config::AutoConf::LMU->check_lmu_prerequisites.*/1;/; s/^inc::Config::AutoConf::LMU->write_config_h.*/1;/' Makefile.PL
                  fi
                  $PERL -I. Makefile.PL LINKTYPE=static >/dev/null
                  make -j$NIX_BUILD_CORES CC="$CC" LD="$CC" AR="$AR" OPTIMIZE="-O2" static pm_to_blib >/dev/null )
              done
              weakenArchive \
                pure/PerlIOutf8_strict/blib/arch/auto/PerlIO/utf8_strict/utf8_strict.a \
                PerlIOBase_flush_linebuf
              ALLA="$ALLA $(find pure -path '*/blib/arch/auto/*.a' | tr '\n' ' ')"
              EXTS="$EXTS $(find pure -path '*/blib/arch/auto/*.a' | sed -E 's|.*/blib/arch/auto/||; s|/[^/]*\.a$||' | sort -u | tr '\n' ' ')"

              # ===== (2) Text::BibTeX (+ bundled btparse) =====
              mkdir -p bibtex && tar xf "$TEXTBIBTEX_SRC" -C bibtex --strip-components=1
              ( cd bibtex
                sed -e 's|\[% ALLOCA_H %\]|define HAVE_ALLOCA_H 1|' \
                    -e 's|\[% STRLCAT %\]|define HAVE_STRLCAT 1|' \
                    -e 's|\[% VSNPRINTF %\]|define HAVE_VSNPRINTF 1|' \
                    -e 's|\[% PACKAGE %\]|"libbtparse"|g' \
                    -e 's|\[% FPACKAGE %\]|"libbtparse 0.91"|' \
                    -e 's|\[% VERSION %\]|"0.91"|' \
                    btparse/src/bt_config.h.in > btparse/src/bt_config.h
                for c in btparse/src/*.c; do
                  $CC -O2 -D_FORTIFY_SOURCE=1 -Ibtparse/src -Ibtparse/pccts -c "$c" -o "''${c%.c}.o"
                done
                $AR cr libbtparse.a btparse/src/*.o
                $PERL -MExtUtils::ParseXS -e \
                  'ExtUtils::ParseXS->new->process_file(filename=>"xscode/BibTeX.xs", output=>"BibTeX.c", typemap=>["'"$PRIVLIB"'/ExtUtils/typemap","'"$PWD"'/typemap"])'
                $CC -O2 $CCFLAGS -DVERSION='"0.91"' -DXS_VERSION='"0.91"' -I"$ARCHLIB/CORE" -Ibtparse/src -Ixscode -c BibTeX.c -o BibTeX.o
                $CC -O2 $CCFLAGS -I"$ARCHLIB/CORE" -Ibtparse/src -Ixscode -c xscode/btxs_support.c -o btxs_support.o
                $AR cr BibTeX.a BibTeX.o btxs_support.o )
              ALLA="$ALLA bibtex/BibTeX.a bibtex/libbtparse.a"; EXTS="$EXTS Text/BibTeX"

              # ===== (3) XML::LibXML (+ system libxml2) =====
              mkdir -p libxml && tar xf "$XMLLIBXML_SRC" -C libxml --strip-components=1
              ( cd libxml
                for xs in LibXML Devel; do
                  $PERL -MExtUtils::ParseXS -e \
                    'ExtUtils::ParseXS->new->process_file(filename=>$ARGV[0].".xs", output=>$ARGV[0].".c", typemap=>["'"$PRIVLIB"'/ExtUtils/typemap","'"$PWD"'/typemap"])' $xs
                done
                for c in LibXML Devel dom perl-libxml-mm perl-libxml-sax xpath Av_CharPtrPtr; do
                  $CC -O2 $CCFLAGS $XML2_CF -DHAVE_UTF8 -I"$ARCHLIB/CORE" -I. -c "$c.c" -o "$c.o"
                done
                $AR cr LibXML.a LibXML.o Devel.o dom.o perl-libxml-mm.o perl-libxml-sax.o xpath.o Av_CharPtrPtr.o )
              ALLA="$ALLA libxml/LibXML.a"; EXTS="$EXTS XML/LibXML XML/LibXML/Devel"

              # ===== (4) XML::LibXSLT (+ system libxslt/libexslt, shares libxml2) =====
              mkdir -p libxslt && tar xf "$XMLLIBXSLT_SRC" -C libxslt --strip-components=1
              ( cd libxslt
                $PERL -MExtUtils::ParseXS -e \
                  'ExtUtils::ParseXS->new->process_file(filename=>"LibXSLT.xs", output=>"LibXSLT.c", typemap=>["'"$PRIVLIB"'/ExtUtils/typemap","'"$PWD"'/typemap"])'
                for c in LibXSLT perl-libxml-mm; do
                  $CC -O2 $CCFLAGS $XML2_CF $XSLT_CF -I"$ARCHLIB/CORE" -I. -c "$c.c" -o "$c.o"
                done
                $AR cr LibXSLT.a LibXSLT.o perl-libxml-mm.o )
              ALLA="$ALLA libxslt/LibXSLT.a"; EXTS="$EXTS XML/LibXSLT"

              # ===== (5) Unicode::LineBreak (+ bundled sombok) =====
              mkdir -p linebreak && tar xf "$LINEBREAK_SRC" -C linebreak --strip-components=1
              ( cd linebreak
                $PERL -I. Makefile.PL >/dev/null
                ( cd sombok
                  $PERL Makefile.PL >/dev/null
                  make -j$NIX_BUILD_CORES CC="$CC" LD="$CC" AR="$AR" OPTIMIZE="-O2" >/dev/null )
                $PERL -MExtUtils::ParseXS -e \
                  'ExtUtils::ParseXS->new->process_file(filename=>"LineBreak.xs", output=>"LineBreak.c", typemap=>["'"$PRIVLIB"'/ExtUtils/typemap","'"$PWD"'/typemap"])'
                $CC -O2 $CCFLAGS -DVERSION='"2019.001"' -DXS_VERSION='"2019.001"' -I"$ARCHLIB/CORE" -Isombok/include -I. -c LineBreak.c -o LineBreak.o
                $AR cr LineBreak.a LineBreak.o )
              ALLA="$ALLA linebreak/LineBreak.a $(find linebreak/sombok -name 'libsombok*.a' | head -1)"; EXTS="$EXTS Unicode/LineBreak"

              # ===== (6) Params::Validate (Build.PL bypass) =====
              mkdir -p params && tar xf "$PARAMSVALIDATE_SRC" -C params --strip-components=1
              ( cd params
                $PERL -MExtUtils::ParseXS -e \
                  'ExtUtils::ParseXS->new->process_file(filename=>"lib/Params/Validate/XS.xs", output=>"PV_XS.c", typemap=>["'"$PRIVLIB"'/ExtUtils/typemap"])'
                $CC -O2 $CCFLAGS -DVERSION='"1.31"' -DXS_VERSION='"1.31"' -I"$ARCHLIB/CORE" -Ic -Ilib/Params/Validate -c PV_XS.c -o PV_XS.o
                $AR cr PV_XS.a PV_XS.o )
              ALLA="$ALLA params/PV_XS.a"; EXTS="$EXTS Params/Validate/XS"

              # ===== VFS objects (shared unpin-vfs core: src/vfs.c + src/miniz.c,
              # github:unpins/unpin-vfs, zstd path, self-EOF mode) =====
              # Compile from basenames copied into cwd (not from an absolute
              # /nix/store source path): clang bakes the compiled source path into
              # the object's debug info; an absolute arg leaks a store ref on darwin
              # (post-embed strip can't run). NOWRAP: vfs.c defines unpinvfs_* and
              # dispatch.c supplies plain main; the VFS is bound by the IR rewrite at
              # relink, so no -DUNPIN_WRAP_TIME64 (the time64 rename is an IR sed).
              cp ${./src}/*.c ${./src}/*.h .
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_NOWRAP -I. -c vfs.c -o vfs.o
              $CC -O2 -DMINIZ_USE_ZSTD -I. -c miniz.c -o miniz.o
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I. -c unpin_zstd.c -o unpin_zstd.o
              $CC -O2 -DUNPIN_DISPATCH_NOWRAP -c dispatch.c -o dispatch.o

              # Stage the @INC: every `use lib` tree from the nixpkgs biber driver
              # (the pure-Perl deps + the XS modules' .pm) under /zip/inc/NNN, plus
              # the static perl's own stdlib under /zip/inc/perl. Then the biber
              # driver at /zip/bin/biber with @INC reset to those /zip paths.
              mkdir -p stage/inc stage/bin
              PERLVER="$($PERL -MConfig -e 'print $Config{version}')"
              ARCHB="$(basename "$ARCHLIB")"
              # The biber module trees are staged from the BUILD-host biber, so an
              # XS module's .pm sits under that tree's arch dir (e.g.
              # site_perl/5.42.0/x86_64-linux-thread-multi/DateTime.pm). @INC must
              # therefore search the BUILD-host archname for these trees, not the
              # target's -- on a true cross they differ (riscv64-linux vs
              # x86_64-linux-thread-multi) and the .pm would be orphaned. For
              # native builds the two coincide, so this is unchanged there.
              BARCHB="$(${bperl} -MConfig -e 'print $Config{archname}')"
              i=0; INCEXPR=""
              for p in $($PERL -ne 'if(/^use lib (.*);\s*$/){my$l=$1;while($l=~/"([^"]+)"/g){print "$1\n"}}' ${biber}/bin/biber); do
                d=$(printf '%03d' $i)
                mkdir -p "stage/inc/$d"; cp -rL "$p"/. "stage/inc/$d"/ 2>/dev/null || true
                # Mirror perl's lib.pm: a `use lib X` also searches X/<version>,
                # X/<archname> and X/<version>/<archname> when present (MakeMaker
                # installs modules under site_perl/<version>/...). We pin @INC by
                # assignment (not `use lib`), so add those subdirs explicitly --
                # checking the real source tree at build time (VFS has no readdir).
                for sub in "" "/$BARCHB" "/$PERLVER" "/$PERLVER/$BARCHB"; do
                  [ -d "$p$sub" ] && INCEXPR="$INCEXPR\"/zip/inc/$d$sub\","
                done
                i=$((i+1))
              done
              # static perl stdlib: privlib already contains the archlib as a
              # subdir, so one copy carries both; add BOTH to @INC (arch-specific
              # core .pm like Cwd/Config live under the <arch> subdir).
              mkdir -p stage/inc/perl
              cp -rL "$PRIVLIB"/. stage/inc/perl/
              ARCHB=$(basename "$ARCHLIB")
              ${lib.optionalString crossCompiling ''
                # perl-cross's -Uusedl build omits a few core .pm that the static
                # boot makes redundant (DynaLoader.pm) -- but modules still
                # `require DynaLoader`. The build-host perl (same 5.42.0) has them;
                # fill any gaps into the staged target arch dir, no-clobber so the
                # target's own arch-specific files (Config*) win. The dev leftovers
                # this drags in (auto/, CORE/, *.a/.h) are scrubbed just below.
                BARCH="$(${bperl} -MConfig -e 'print $Config{archlibexp}')"
                # the privlib copy above came from the read-only nix store, so make
                # the target arch dir writable before filling into it.
                chmod -R u+w "stage/inc/perl/$ARCHB"
                cp -rn "$BARCH"/. "stage/inc/perl/$ARCHB"/ 2>/dev/null || true
              ''}
              INCEXPR="$INCEXPR\"/zip/inc/perl\",\"/zip/inc/perl/$ARCHB\""
              chmod -R u+w stage
              # drop dev/compile leftovers (the XS .so/.a/.h/CORE; we link XS static)
              find stage/inc -type f \( -name '*.so' -o -name '*.a' -o -name '*.h' -o -name '*.ld' -o -path '*/CORE/*' \) -delete
              find stage/inc -depth -type d -empty -delete 2>/dev/null || true
              # /zip/bin/biber = the driver with shebang+original `use lib` dropped
              # and @INC pinned to the staged /zip trees.
              {
                echo "#!/zip/bin/perl"
                echo "BEGIN { @INC = ($INCEXPR); }"
                # Neutralise the driver's `use lib $FindBin::RealBin`: @INC is already
                # fully pinned above and RealBin (=/zip/bin) holds no modules, so the
                # line is dead in the onefile (the original driver used it to find a
                # sibling lib/ on disk). It also can't run under the VFS -- FindBin
                # resolves RealBin via Cwd::abs_path, which follows a path with
                # getcwd/chdir/readlink and so can't resolve a VFS-only /zip path
                # (real paths work). Left in, it yields RealBin="" -> `use lib ""`,
                # which warns and seeds an undef @INC element (a cascade of
                # "uninitialized $_" warnings downstream). Replace it with a no-op,
                # preserving line numbers. Matches the driver comment's stated intent
                # ("original use lib dropped"); the old vendored VFS fork happened to
                # resolve /zip via a built-in dir-stat the canonical core dropped.
                tail -n +3 ${biber}/bin/biber | sed 's|^use lib $FindBin::RealBin;.*|1;|'
              } > stage/bin/biber

              # Scrub /nix store paths out of EVERY staged text file: the STORED
              # shared dict (trained by the nix-lib embed) would bake store-path
              # hashes verbatim -- nix would then retain biber's whole module
              # closure as spurious references.
              grep -rlI '/nix/store/' stage 2>/dev/null | while read -r f; do
                sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
              done
              # The staged tree is NOT packed here: withUnpinEmbed (flake tail)
              # copies it as the runtime stage and packs the binary's single EOF
              # ZIP in postFixup (zstd method 93 + shared dict), read back by
              # the VFS's self-EOF mode -- no blob object, no relink for data.

              # ===== relink: perl + 19 XS static-ext + VFS + dispatch =====
              COREEXTS="$(cd "$ARCHLIB/auto" && find . -name '*.a' \
                | sed -e 's|^\./||' -e 's|/[^/]*\.a$||' | sort -u | tr '\n' ' ')"
              # The full set of core static-ext archives. writemain emits a
              # boot_<ext> for each name above, so EVERY matching .a must be on
              # the link line. ExtUtils::Embed ldopts can't be trusted to supply
              # them: it maps $Config{static_ext} -> auto/<ext>/<base>.a, but
              # perl-cross records dist names (PathTools, Scalar/List/Utils) that
              # don't match the on-disk archives (auto/Cwd/Cwd.a, auto/List/Util.a),
              # so cross-ldopts silently drops Cwd/List::Util -> undefined boot_*.
              # Link the archives explicitly; keep $LDO only for syslibs/extralibs.
              COREA="$(find "$ARCHLIB/auto" -name '*.a' | tr '\n' ' ')"
              $PERL -MExtUtils::Miniperl -e 'writemain(@ARGV)' $COREEXTS $EXTS > perlmain.c
              $CC -O2 -c perlmain.c -I"$ARCHLIB/CORE" -o perlmain.o
              LDO="$($PERL -MExtUtils::Embed -e ldopts 2>/dev/null | sed 's/-lperl//')"
              # ===== VFS bind by IR rewrite (engine = all bitcode; neither
              # `ld --wrap` nor `objcopy --redefine-sym` can bind it). Rewrite
              # libperl.a's open/stat/lstat/access refs to the unpinvfs_* shims and
              # perlmain's main -> real_main, then LTO-link with vfs.o (defines the
              # shims under -DUNPIN_VFS_NOWRAP) + dispatch.o (supplies main). ONE path
              # for Linux and darwin, replacing the old --wrap (Linux) / --redefine-sym
              # (darwin) split. =====
              # Rewrite libperl.a AND the core-ext archives (Cwd/List::Util). The
              # old -Wl,--wrap was GLOBAL -- it caught every caller's open/stat/lstat,
              # including Cwd's abs_path lstat that FindBin::RealBin uses to resolve
              # /zip/bin. An IR rewrite of libperl.a alone leaves Cwd calling real
              # libc -> /zip/bin "absent" -> RealBin empty -> `use lib ""` seeds an
              # undef @INC element (the "Empty compile time value" + downstream
              # "uninitialized $_" warnings). libperl + the core exts are read-only in
              # the perl store, so copy them local before rewriting.
              cp "$ARCHLIB/CORE/libperl.a" libperl_vfs.a; chmod u+w libperl_vfs.a
              bcrewriteArchive libperl_vfs.a
              COREA_VFS=""
              for a in $COREA; do
                # Name by the FULL auto-relative path: parent-dir+basename alone
                # collides (auto/Hash/Util/Util.a and auto/List/Util/Util.a both
                # -> vfsa_Util_Util.a), so the second clobbers the first and its
                # boot_<ext> goes undefined. Native builds masked it (ExtUtils::
                # Embed ldopts re-supplied the loser); cross drops List::Util from
                # ldopts, so whichever the readdir order clobbered stayed dead.
                b="vfsa_$(echo "''${a#$ARCHLIB/auto/}" | tr / _)"
                cp "$a" "$b"; chmod u+w "$b"; bcrewriteArchive "$b"
                COREA_VFS="$COREA_VFS $b"
              done
              if isbc perlmain.o; then
                $MT opt -S perlmain.o -o perlmain.ll
                sed -i -e 's/@main\b/@real_main/g' perlmain.ll
                $MT opt perlmain.ll -o perlmain.o
                rm -f perlmain.ll
              fi
              # LTO link; bitcode is globally resolved, so no --start-group.
              # -Wl,-u,malloc: the whole-program LTO internalizes musl's WEAK malloc
              # alias, but sombok's linebreak_add_prep references it late -> "undefined
              # symbol: malloc". Force-keep it (per-package analogue of nix-lib's mega
              # bitcodeLibcForce). Linux only; darwin's libc has no such weak alias.
              $CC -O2 -o biber \
                ${lib.optionalString (!isDarwin) "-Wl,-u,malloc"} \
                perlmain.o vfs.o miniz.o unpin_zstd.o dispatch.o \
                $ALLA $COREA_VFS "$EXSLT_A" "$XSLT_A" "$XML2_A" \
                $LDO libperl_vfs.a -lm
              runHook postBuild
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp biber $out/bin/biber
              # Expose the scrubbed @INC stage as a store path so the post-build
              # embed (runtimeEmbed → unpinEmbedWrap) can pack it: the build dir
              # is gone by then, so the in-build `$NIX_BUILD_TOP/work/stage` is no
              # longer reachable. Hidden under $out (not shipped — the final binary
              # only copies bin/biber; this rides in the base closure).
              cp -a "$NIX_BUILD_TOP/work/stage" "$out/.unpin-inc"
              runHook postInstall
            '';
          };
        in
        # The PRISTINE biber base (no embed); the @INC tree + man are embedded
        # once, post-build, via runtimeEmbed.native → unpinEmbedWrap (the single
        # embed path). biberBin ships no share/man, so manFallback borrows the
        # version-locked biber.1 from the build-host biber (POD-generated,
        # OS-independent roff) — the same graft windows.nix applies.
        biberBin;
      base = ulib.mkStandaloneFlake {
        inherit self;
        name = "biber";
        # Build via the unpin-llvm engine: pkgsStatic is swapped to the engine
        # stdenv, so perl + the 19 hand-built XS + libxml2/libxslt all compile to
        # LLVM bitcode and the binary is LTO-linked (whole-program opt, the same
        # toolchain perl/curl/nmap/tcc use). The engine gates itself to native +
        # darwin; the Linux crosses and windows (mingw) stay off-engine. The /zip
        # @INC embed is unchanged; the VFS is bound by IR symbol rewrite in `mk`
        # (bitcode has no `--wrap` / objcopy).
        engine = "unpin-llvm";
        embedMan = true;
        smoke = [ "--version" ];
        smokePattern = "biber";
        build = pkgs: mk pkgs;
        # Windows is mingw-NATIVE (not cosmo): nixpkgs' perl-cross only gets
        # part-way, so windows.nix runs winfix-spike.sh (postConfigure) to make a
        # real win32 perl, folds the 19 XS as static extensions, and relinks with
        # the four win32_* I/O wraps + main wrap serving the embedded @INC ZIP.
        # Lands as packages.x86_64-linux."windows-x86_64".
        windowsBuild = pkgs: (winMod pkgs).base;
        runtimeEmbed = {
          native = pkgs: base: {
            man = true;
            manFallback = "${pkgs.buildPackages.biber.man or pkgs.buildPackages.biber}";
            runtimeStage = ''
              cp -a ${base}/.unpin-inc/. "$__unpin_stage/"
              chmod -R u+w "$__unpin_stage"
            '';
          };
          windows = pkgs: base: (winMod pkgs).embed;
        };
      };
      winMod = import ./windows.nix { inherit ulib; };
    in
    # Ship: x86_64/aarch64-linux (native) + the four cross-linux arches
    # (i686/ppc64le/riscv64/armv7l, via the build-host-perl codegen flow) +
    # aarch64-darwin (native) + `darwin-x86_64` (the darwin<->darwin cross,
    # which this flake already supports — cross_darwin.pl, the $INODE64
    # redefs). CI has no x86_64-darwin runner, so that cross attr is the
    # ONLY path to an Intel macOS release asset; the native x86_64-darwin
    # output only ever builds locally.
    base;
}
