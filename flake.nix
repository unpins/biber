{
  description = "Standalone build of biber";

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
  # packed into the executable as a ZIP and served by a linker-level VFS: open/
  # stat are intercepted (Linux `-Wl,--wrap`) and any `/zip/...` path is read
  # from the embedded blob, so there is no companion module tree on disk. The
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
          perl = sp.perl;
          lib = pkgs.lib;
          pp = sp.perlPackages;
          biber = pkgs.biber;

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
            nativeBuildInputs = [ perl pkgs.zip pkgs.file ];
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
              # off64_t/LFS64 for every external XS on static-musl perl. UNPIN_VFS_OFF
              # keeps the VFS dormant for build-time perl runs (writemain etc.).
              export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -D_LARGEFILE64_SOURCE"
              export UNPIN_VFS_OFF=1
              PERL=${perl}/bin/perl
              ARCHLIB="$($PERL -MConfig -e 'print $Config{archlibexp}')"
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
              $OBJCOPY --weaken-symbol=PerlIOBase_flush_linebuf \
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

              # ===== VFS objects + the @INC blob =====
              $CC -O2 -I${./src} -c ${./src/vfs_miniz.c} -o vfs.o
              $CC -O2 -I${./src} -c ${./src/miniz.c} -o miniz.o
              $CC -O2 -c ${./src/dispatch.c} -o dispatch.o

              # Stage the @INC: every `use lib` tree from the nixpkgs biber driver
              # (the pure-Perl deps + the XS modules' .pm) under /zip/inc/NNN, plus
              # the static perl's own stdlib under /zip/inc/perl. Then the biber
              # driver at /zip/bin/biber with @INC reset to those /zip paths.
              mkdir -p stage/inc stage/bin
              PERLVER="$($PERL -MConfig -e 'print $Config{version}')"
              ARCHB="$(basename "$ARCHLIB")"
              i=0; INCEXPR=""
              for p in $($PERL -ne 'if(/^use lib (.*);\s*$/){my$l=$1;while($l=~/"([^"]+)"/g){print "$1\n"}}' ${biber}/bin/biber); do
                d=$(printf '%03d' $i)
                mkdir -p "stage/inc/$d"; cp -r "$p"/. "stage/inc/$d"/ 2>/dev/null || true
                # Mirror perl's lib.pm: a `use lib X` also searches X/<version>,
                # X/<archname> and X/<version>/<archname> when present (MakeMaker
                # installs modules under site_perl/<version>/...). We pin @INC by
                # assignment (not `use lib`), so add those subdirs explicitly --
                # checking the real source tree at build time (VFS has no readdir).
                for sub in "" "/$ARCHB" "/$PERLVER" "/$PERLVER/$ARCHB"; do
                  [ -d "$p$sub" ] && INCEXPR="$INCEXPR\"/zip/inc/$d$sub\","
                done
                i=$((i+1))
              done
              # static perl stdlib: privlib already contains the archlib as a
              # subdir, so one copy carries both; add BOTH to @INC (arch-specific
              # core .pm like Cwd/Config live under the <arch> subdir).
              mkdir -p stage/inc/perl
              cp -r "$PRIVLIB"/. stage/inc/perl/
              ARCHB=$(basename "$ARCHLIB")
              INCEXPR="$INCEXPR\"/zip/inc/perl\",\"/zip/inc/perl/$ARCHB\""
              chmod -R u+w stage
              # drop dev/compile leftovers (the XS .so/.a/.h/CORE; we link XS static)
              find stage/inc -type f \( -name '*.so' -o -name '*.a' -o -name '*.h' -o -name '*.ld' -o -path '*/CORE/*' \) -delete
              find stage/inc -depth -type d -empty -delete 2>/dev/null || true
              # scrub /nix store paths out of Config (the only files that leak them)
              find stage/inc -name 'Config_heavy.pl' -o -name 'Config.pm' | while read -r f; do
                sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
              done
              # /zip/bin/biber = the driver with shebang+original `use lib` dropped
              # and @INC pinned to the staged /zip trees.
              {
                echo "#!/zip/bin/perl"
                echo "BEGIN { @INC = ($INCEXPR); }"
                tail -n +3 ${biber}/bin/biber
              } > stage/bin/biber

              ( cd stage && zip -9 -X -r -q ../incblob inc bin )
              [ -f incblob ] || mv incblob.zip incblob
              cp ${./src/blob.S} blob.S
              $CC -c blob.S -o incblob.o

              # ===== relink: perl + 19 XS static-ext + VFS + blob + dispatch =====
              COREEXTS="$(cd "$ARCHLIB/auto" && find . -name '*.a' \
                | sed -e 's|^\./||' -e 's|/[^/]*\.a$||' | sort -u | tr '\n' ' ')"
              $PERL -MExtUtils::Miniperl -e 'writemain(@ARGV)' $COREEXTS $EXTS > perlmain.c
              $CC -O2 -c perlmain.c -I"$ARCHLIB/CORE" -o perlmain.o
              LDO="$($PERL -MExtUtils::Embed -e ldopts 2>/dev/null | sed 's/-lperl//')"
              $CC -O2 -o biber \
                -Wl,--wrap=open -Wl,--wrap=stat -Wl,--wrap=lstat -Wl,--wrap=access -Wl,--wrap=main \
                perlmain.o vfs.o miniz.o dispatch.o incblob.o \
                -Wl,--start-group $ALLA "$EXSLT_A" "$XSLT_A" "$XML2_A" \
                $LDO "$ARCHLIB/CORE/libperl.a" -Wl,--end-group -lm
              runHook postBuild
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp biber $out/bin/biber
              runHook postInstall
            '';
          };
        in
        biberBin;
      base = ulib.mkStandaloneFlake {
        inherit self;
        name = "biber";
        embedMan = true;
        smoke = [ "--version" ];
        smokePattern = "biber";
        # darwin + windows are proven in the spike but their VFS-embed is not
        # wired here yet; ship Linux first.
        linuxOnly = true;
        build = pkgs: mk pkgs;
      };
    in
    # mkStandaloneFlake also emits the cross linux targets (linux-i686/ppc64le/
    # riscv64/armv7l). The recipe runs the *target* perl for codegen, which only
    # works where the build host can execute it -- the two NATIVE arches
    # (x86_64 + aarch64-via-arm-runner). The cross targets need the perl-cross
    # codegen flow (build-host perl + target toolchain), not yet wired. Drop them
    # from `packages` so action-build's auto-discovered matrix builds only what
    # works; native x86_64 and aarch64 ship now.
    base // {
      packages = base.packages // {
        x86_64-linux = builtins.removeAttrs (base.packages.x86_64-linux or { })
          [ "linux-i686" "linux-ppc64le" "linux-riscv64" ];
        aarch64-linux = builtins.removeAttrs (base.packages.aarch64-linux or { })
          [ "linux-armv7l" ];
      };
    };
}
