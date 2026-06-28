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
          perl = sp.perl.overrideAttrs (old: {
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
              ++ lib.optionals isDarwin [ "-Dranlib=${prefix}ranlib" ];
            postPatch = (old.postPatch or "")
              + lib.optionalString isDarwin ''
                substituteInPlace installperl \
                  --replace-fail '&& $Config{useshrplib}' '&& $Config{useshrplib} eq "true"'
              ''
              # perl-cross has no darwin support and assumes an ELF build host
              # (readelf/objdump); on a darwin build host (the darwin<->darwin
              # cross) rewrite those probes to compile-only, cross-safe forms.
              + lib.optionalString (crossCompiling && isDarwin) ''
                ${bperl} ${./src/cross_darwin.pl}
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
          # darwin has no musl off64 hack; ld64 has no --start-group (it re-scans
          # archives); Mach-O C symbols carry a `_` prefix; cctools has no objcopy
          # (use llvm-objcopy). crypt.h / libcrypt / libiconv aren't on darwin's
          # default paths but perl's recorded ccflags/ldopts reference them.
          lfs = if isDarwin then "" else "-D_LARGEFILE64_SOURCE";
          cryptInc = if isDarwin then "-I${lib.getDev sp.libxcrypt}/include" else "";
          cryptLib = if isDarwin
            then "-L${lib.getLib sp.libxcrypt}/lib -L${lib.getLib sp.libiconv}/lib -liconv"
            else "";
          objcopy = if isDarwin then "${pkgs.buildPackages.llvm}/bin/llvm-objcopy" else "$OBJCOPY";
          usym = if isDarwin then "_" else "";   # Mach-O C-symbol underscore prefix
          # darwin has no --wrap: rename libperl.a's open/stat to the VFS entry
          # points by hand. x86_64-darwin carries the $INODE64 ABI suffix on
          # stat/lstat; aarch64-darwin uses plain _stat/_lstat.
          darwinRedef =
            let suf = if host.isAarch64 or false then "" else "$INODE64";
            in lib.concatStringsSep " " [
              "--redefine-sym _open=_unpinvfs_open"
              "--redefine-sym '_stat${suf}=_unpinvfs_stat'"
              "--redefine-sym '_lstat${suf}=_unpinvfs_lstat'"
              "--redefine-sym _access=_unpinvfs_access"
            ];
          # 32-bit musl is _REDIR_TIME64: libc renames stat/lstat to
          # __stat_time64/__lstat_time64 in the headers, so a bare --wrap=stat
          # never fires. The VFS wraps those names too (see src/vfs.c,
          # guarded by -DUNPIN_WRAP_TIME64). Linux 32-bit only (i686/armv7l).
          wrap32 = (host.parsed.cpu.bits or 64) == 32;
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
              ${objcopy} --weaken-symbol=${usym}PerlIOBase_flush_linebuf \
                pure/PerlIOutf8_strict/blib/arch/auto/PerlIO/utf8_strict/utf8_strict.a
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
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF ${lib.optionalString wrap32 "-DUNPIN_WRAP_TIME64"} -I${./src} -c ${./src/vfs.c} -o vfs.o
              $CC -O2 -DMINIZ_USE_ZSTD -I${./src} -c ${./src/miniz.c} -o miniz.o
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${./src} -c ${./src/unpin_zstd.c} -o unpin_zstd.o
              $CC -O2 -c ${./src/dispatch.c} -o dispatch.o

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
                tail -n +3 ${biber}/bin/biber
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
              ${if isDarwin then ''
                # darwin: no --wrap. dispatch.o supplies _main (rename perlmain.o's
                # _main -> _real_main); libperl.a's open/stat are renamed to the VFS
                # entry points. ld64 re-scans archives, so no --start-group.
                ${objcopy} --redefine-sym _main=_real_main perlmain.o
                cp "$ARCHLIB/CORE/libperl.a" libperl_vfs.a; chmod u+w libperl_vfs.a
                ${objcopy} ${darwinRedef} libperl_vfs.a
                $CC -O2 -o biber \
                  perlmain.o vfs.o miniz.o unpin_zstd.o dispatch.o \
                  $ALLA $COREA "$EXSLT_A" "$XSLT_A" "$XML2_A" \
                  $LDO libperl_vfs.a -lm
              '' else ''
                $CC -O2 -o biber \
                  -Wl,--wrap=open -Wl,--wrap=stat -Wl,--wrap=lstat -Wl,--wrap=access -Wl,--wrap=main \
                  ${lib.optionalString wrap32 "-Wl,--wrap=__stat_time64 -Wl,--wrap=__lstat_time64"} \
                  perlmain.o vfs.o miniz.o unpin_zstd.o dispatch.o \
                  -Wl,--start-group $ALLA $COREA "$EXSLT_A" "$XSLT_A" "$XML2_A" \
                  $LDO "$ARCHLIB/CORE/libperl.a" -Wl,--end-group -lm
              ''}
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
