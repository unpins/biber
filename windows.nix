# Windows (mingw-NATIVE) half of biber. Built FROM x86_64-linux via
# pkgsCross.mingwW64, so it lands under packages.x86_64-linux."windows-x86_64".
#
# Same single-binary design as Linux/darwin: 19 XS folded in as static extensions
# + the whole @INC packed into the .exe as a ZIP, served by a linker-level VFS.
# Windows has no memfd, so the VFS materialises each /zip entry to a temp file and
# delegates to perl's real win32_{open,stat,lstat,access} (intercepted with mingw
# `ld --wrap`); `--wrap=main` injects the embedded /zip/bin/biber driver.
#
# Two things differ from Linux:
#   1. The interpreter is a real win32-native perl. nixpkgs' perl-cross only goes
#      part-way, so winfix-spike.sh (postConfigure) overlays the win32 OS/ABI
#      config and wires the win32 host layer (win32/*.c) into libperl.
#   2. The .exe can't run on the build host, so the Perl-side codegen
#      (xsubpp/ParseXS, writemain) runs with the build-host perl while the mingw
#      cross toolchain compiles the C -- exactly how nixpkgs/perl-cross
#      cross-builds native modules.
{ ulib }:
pkgs:
let
  lib = pkgs.lib;
  cross = pkgs.pkgsCross.mingwW64;
  bperl = "${pkgs.buildPackages.perl}/bin/perl";       # native perl: winfix + codegen
  biber = pkgs.buildPackages.biber;                     # arch-indep driver + @INC trees
  winDir = ./src/win;
  mcfA = "${cross.windows.mcfgthreads}/lib";            # static libmcfgthread.a
  archSub = "lib/perl5/5.42.0/MSWin32-x64";

  # static mingw libxml2/libxslt (+ their static deps) -- the XML XS link these.
  msc = ulib.mingwStaticCross pkgs;
  winLibxml2 = msc.libxml2;
  winLibxslt = msc.libxslt;

  # Windows-only pure-Perl deps the build-host (linux) biber closure omits because
  # they are loaded only `if $^O eq 'MSWin32'`. IPC::Run3 (in biber's closure)
  # requires Win32::ShellQuote on Windows; without it Biber::Utils dies. Arch-
  # independent .pm, staged into the @INC blob below.
  win32ShellQuote = pkgs.perlPackages.Win32ShellQuote;

  # Win32::Unicode (XAICRON 0.38) -- NOT packaged in nixpkgs. On Windows,
  # Biber::Utils routes file slurp/spew/stat/size through Win32::Unicode::File
  # whenever the system ANSI code page isn't UTF-8 (Win32::GetACP() != 65001 --
  # the usual case, e.g. CP1252), so its OO filehandle + statW + file_size are
  # mandatory for the .bcf->.bbl path. Pure-Perl wrappers over a single XS (the
  # eight xs/*.xs fold into one `Win32::Unicode` ext); no external C library and
  # no Win32::API dependency, so it builds by hand like the other static XS.
  w32uSrc = pkgs.fetchurl {
    url = "mirror://cpan/authors/id/X/XA/XAICRON/Win32-Unicode-0.38.tar.gz";
    hash = "sha256-xSzZBJxR7cXPvQZaySpDJ+e4eMrnZOQMao2xyJ7ig40=";
  };

  # win32 ccflags for an external XS compiled against the installed base. mingw-gcc
  # predefines WIN32; spell out WIN64/PERLDLL. The win32 host headers are staged
  # into CORE (postInstall), so -I<CORE> resolves win32.h + the unix-shim tree.
  winXsCflags = "-D_GNU_SOURCE -std=gnu17 -fpermissive -DWIN64 -DPERLDLL";

  # win32-native perl base: drop the cross coreutils-mingw postPatch (bakes a
  # broken /bin/pwd into Cwd.pm + drags the failing coreutils-mingw build), apply
  # the static-ext aux patch, run winfix-spike after perl-cross configure, and
  # stage the win32 host headers into CORE so external XS find them.
  winPerl = cross.perl.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/ext-re-static-aux.patch ];
    postPatch = ''
      substituteInPlace cnf/configure_tool.sh --replace-fail "cc -E -P" "cc -E"
    '';
    postConfigure = (old.postConfigure or "") + ''
      echo "=== unpin winfix-spike (win32-native, real @INC) ==="
      NPERL=${bperl} bash ${winDir}/winfix-spike.sh ${winDir} ${mcfA}
    '';
    postInstall = (old.postInstall or "") + ''
      CORE=$(echo "$out"/${archSub}/CORE)
      cp win32/*.h "$CORE"/
      cp -r win32/include/* "$CORE"/
    '';
  });

  # The 14 pure-XS modules (no external C library) of biber's closure.
  pp = pkgs.perlPackages;
  pureXs = {
    inherit (pp) DateSimple Clone EncodeHanExtra ReadonlyXS EncodeEUCJPASCII
                 EncodeJIS2K DateTime PerlIOutf8_strict SubIdentify SortKey
                 autovivification ListMoreUtilsXS TextCSV_XS HTMLParser;
  };
  pureXsList = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (n: v: "${n} ${v.src}") pureXs);
in
cross.stdenv.mkDerivation {
  pname = "biber";
  version = biber.version or "2.21";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.buildPackages.perl pkgs.zip pkgs.file ];
  PURE_XS_LIST = pureXsList;
  TEXTBIBTEX_SRC = pp.TextBibTeX.src;
  XMLLIBXML_SRC = pp.XMLLibXML.src;
  XMLLIBXSLT_SRC = pp.XMLLibXSLT.src;
  LINEBREAK_SRC = pp.UnicodeLineBreak.src;
  PARAMSVALIDATE_SRC = pp.ParamsValidate.src;
  # perl source tarball -> its bundled cpan/Win32 (the Win32 module, an XS that
  # wraps the native Win32 API). Not a standalone perlPackage, so take it from
  # the perl dist; same 5.42.0 source the interpreter is built from.
  WIN32_SRC = pkgs.perl.src;
  W32U_SRC = w32uSrc;
  meta = (biber.meta or { }) // { mainProgram = "biber"; };

  buildPhase = ''
    runHook preBuild
    BPERL=${bperl}
    ARCH="${winPerl}/${archSub}"
    CORE="$ARCH/CORE"
    # codegen perl = build-host perl pointed at the target archlib for %Config
    # (Config_heavy.pl is data; same 5.42.0). Shadow Cwd with the host copy (the
    # target's static Cwd XS can't run here) -- same as the linux/darwin cross.
    BARCH_B="$($BPERL -MConfig -e 'print $Config{archlibexp}')"
    mkdir -p "$NIX_BUILD_TOP/cwddir/auto"
    ln -sf "$BARCH_B/Cwd.pm" "$NIX_BUILD_TOP/cwddir/"
    ln -sf "$BARCH_B/auto/Cwd" "$NIX_BUILD_TOP/cwddir/auto/"
    PERL="$BPERL -I$NIX_BUILD_TOP/cwddir -I$ARCH"
    TYPEMAP="$($BPERL -MConfig -e 'print $Config{privlibexp}')/ExtUtils/typemap"
    PRIVLIB="$ARCH/.."
    # LIB*_STATIC: tell the win32 libxml2/libxslt headers NOT to decorate their
    # prototypes with __declspec(dllimport) -- we link the static .a, so the
    # symbols are local, not DLL imports (__imp_*).
    XML2_CF="-I${winLibxml2.dev}/include/libxml2 -DLIBXML_STATIC"
    XSLT_CF="-I${winLibxslt.dev}/include -DHAVE_EXSLT -DLIBXSLT_STATIC -DLIBEXSLT_STATIC"
    XML2_A="${winLibxml2.out}/lib/libxml2.a"
    XSLT_A="${winLibxslt.out}/lib/libxslt.a"
    EXSLT_A="${winLibxslt.out}/lib/libexslt.a"
    mkdir -p work && cd work
    ALLA=""; EXTS=""

    # ===== (0) Win32 module (provides Win32::GetCwd / GetFullPathName) =====
    # Critical on Windows: Cwd.pm's MSWin32 path binds cwd/getcwd to _NT_cwd,
    # which is _win32_cwd (native Win32::GetCwd) only if `defined &Win32::GetCwd`
    # at Cwd compile time -- otherwise _win32_cwd_simple, which shells out
    # `cmd /c cd` for EVERY cwd lookup. biber resolves cwd hundreds of times at
    # startup, so without Win32 the .exe drowns in cmd.exe spawns and never makes
    # progress (looks like a hang). Build Win32 as a static ext and `require` it
    # before anything pulls Cwd (see the wrapper BEGIN below) so the native,
    # non-spawning path is taken. Its Makefile.PL die()s off-Windows, so build it
    # by hand like the other XS (xsubpp on the build perl, mingw $CC for the C).
    mkdir -p win32mod
    tar xf "$WIN32_SRC" -C win32mod --strip-components=3 --wildcards '*/cpan/Win32/*'
    ( cd win32mod
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"Win32.xs", output=>"Win32.c", typemap=>["'"$TYPEMAP"'"])'
      $CC -O2 ${winXsCflags} -DVERSION='"0.59_01"' -DXS_VERSION='"0.59_01"' -I"$CORE" -c Win32.c -o Win32.o
      $AR cr Win32.a Win32.o )
    ALLA="$ALLA win32mod/Win32.a"; EXTS="$EXTS Win32"

    # ===== (0b) Win32::Unicode (Win32::Unicode::File for biber's file I/O) =====
    # biber's Biber::Utils routes slurp/spew/stat/size of file paths through
    # Win32::Unicode::File when Win32::GetACP() != 65001 (the common non-UTF-8
    # Windows ANSI code page). Not in nixpkgs, so vendor XAICRON's dist and build
    # its single XS by hand: the eight xs/*.xs fold into one `Win32::Unicode` ext
    # -- XS.xs's BOOT chains each sub-module's boot_Win32__Unicode__*, and the
    # ext name `Win32/Unicode` makes writemain register `Win32::Unicode::bootstrap`,
    # which XSLoader::load('Win32::Unicode') (from Win32/Unicode/XS.pm) resolves
    # statically. ppport.h via Devel::PPPort (Module::Install::XSUtil would emit
    # it on a normal build). mingw needs <sys/utime.h> for struct _utimbuf /
    # _wutime in File.xs (MSVC drags it in via <sys/stat.h>; mingw does not).
    mkdir -p w32u
    tar xf "$W32U_SRC" -C w32u --strip-components=1
    ( cd w32u
      sed -i 's|#include <windows.h>|#include <windows.h>\n#include <sys/utime.h>|' xs/File.xs
      $PERL -MDevel::PPPort -e 'Devel::PPPort::WriteFile("ppport.h")'
      for x in XS File Dir Console Util Error Native Process; do
        $PERL -MExtUtils::ParseXS -e \
          'ExtUtils::ParseXS->new->process_file(filename=>"xs/'"$x"'.xs", output=>"'"$x"'.c", typemap=>["'"$TYPEMAP"'","'"$PWD"'/xs/typemap"])'
        $CC -O2 ${winXsCflags} -DVERSION='"0.38"' -DXS_VERSION='"0.38"' -I"$CORE" -I. -c "$x.c" -o "$x.o"
      done
      $AR cr Win32_Unicode.a XS.o File.o Dir.o Console.o Util.o Error.o Native.o Process.o )
    ALLA="$ALLA w32u/Win32_Unicode.a"; EXTS="$EXTS Win32/Unicode"

    # ===== (0c) Encode::Unicode (utf16-le, needed by Win32::Unicode::Util) =====
    # perl-cross builds only the top-level Encode XS (ascii/8859-1/cp1252/null via
    # the def_t table baked into Encode.a), not Encode's sub-encoding dists. So
    # Encode::Unicode -- which registers UTF-16/UTF-32/UCS-2 -- is absent and
    # Encode::find_encoding('utf16-le') returns undef. Win32::Unicode::Util encodes
    # every path to UTF-16LE for the wide Win32 API, so without it biber dies
    # ("Can't call method encode on an undefined value"). On Linux/mac Win32::
    # Unicode is never loaded, so the gap was invisible there. Unicode.xs is
    # hand-written (no enc2xs tables), so build it like the other XS; it #includes
    # ../Encode/encode.h, which the strip-3 extract places at encu/Encode/encode.h.
    # Encode/Config.pm (staged from winPerl) maps UTF-16LE -> Encode::Unicode, so
    # once the ext is registered the load-on-demand from find_encoding resolves it.
    mkdir -p encu
    tar xf "$WIN32_SRC" -C encu --strip-components=3 --wildcards '*/cpan/Encode/*'
    ( cd encu
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"Unicode/Unicode.xs", output=>"Unicode/Unicode.c", typemap=>["'"$TYPEMAP"'"])'
      $CC -O2 ${winXsCflags} -DVERSION='"2.20"' -DXS_VERSION='"2.20"' -I"$CORE" -c Unicode/Unicode.c -o Unicode/Unicode.o
      $AR cr Encode_Unicode.a Unicode/Unicode.o )
    ALLA="$ALLA encu/Encode_Unicode.a"; EXTS="$EXTS Encode/Unicode"

    # ===== (1) the 14 pure-XS via the generic loop =====
    mkdir -p pure
    echo "$PURE_XS_LIST" | while read -r name src; do
      [ -z "$name" ] && continue
      mkdir -p "pure/$name" && tar xf "$src" -C "pure/$name" --strip-components=1
      ( cd "pure/$name"
        if [ -f inc/Config/AutoConf/LMU.pm ]; then
          cp ${./src/LMUconfig.h} LMUconfig.h
          $PERL -i -pe 's/^inc::Config::AutoConf::LMU->check_lmu_prerequisites.*/1;/; s/^inc::Config::AutoConf::LMU->write_config_h.*/1;/' Makefile.PL
        fi
        # PERL/FULLPERL pinned to the build perl: MakeMaker's find_perl uses the
        # target $Config{perlpath}+.exe (the win perl.exe, not runnable here) and
        # otherwise leaves $(PERL) empty -> the xsubpp rule is a blank command.
        $PERL -I. Makefile.PL LINKTYPE=static PERL="$BPERL" FULLPERL="$BPERL" >/dev/null
        make -j$NIX_BUILD_CORES CC="$CC" LD="$CC" AR="$AR" OPTIMIZE="-O2" static pm_to_blib >/dev/null )
    done
    # mingw binutils objcopy (COFF-aware; llvm-objcopy rejects --weaken-symbol on
    # COFF). Weaken the bundled PerlIOBase_flush_linebuf so libperl's wins.
    $OBJCOPY --weaken-symbol=PerlIOBase_flush_linebuf \
      pure/PerlIOutf8_strict/blib/arch/auto/PerlIO/utf8_strict/utf8_strict.a
    ALLA="$ALLA $(find pure -path '*/blib/arch/auto/*.a' | tr '\n' ' ')"
    EXTS="$EXTS $(find pure -path '*/blib/arch/auto/*.a' | sed -E 's|.*/blib/arch/auto/||; s|/[^/]*\.a$||' | sort -u | tr '\n' ' ')"

    # ===== (2) Text::BibTeX (+ bundled btparse) =====
    mkdir -p bibtex && tar xf "$TEXTBIBTEX_SRC" -C bibtex --strip-components=1
    ( cd bibtex
      # mingw: vsnprintf yes; no <alloca.h> (alloca lives in malloc.h) and no
      # strlcat -> let btparse use its bundled fallbacks.
      sed -e 's|\[% ALLOCA_H %\]|undef HAVE_ALLOCA_H|' \
          -e 's|\[% STRLCAT %\]|undef HAVE_STRLCAT|' \
          -e 's|\[% VSNPRINTF %\]|define HAVE_VSNPRINTF 1|' \
          -e 's|\[% PACKAGE %\]|"libbtparse"|g' \
          -e 's|\[% FPACKAGE %\]|"libbtparse 0.91"|' \
          -e 's|\[% VERSION %\]|"0.91"|' \
          btparse/src/bt_config.h.in > btparse/src/bt_config.h
      for c in btparse/src/*.c; do
        $CC -O2 ${winXsCflags} -Ibtparse/src -Ibtparse/pccts -c "$c" -o "''${c%.c}.o"
      done
      $AR cr libbtparse.a btparse/src/*.o
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"xscode/BibTeX.xs", output=>"BibTeX.c", typemap=>["'"$TYPEMAP"'","'"$PWD"'/typemap"])'
      $CC -O2 ${winXsCflags} -DVERSION='"0.91"' -DXS_VERSION='"0.91"' -I"$CORE" -Ibtparse/src -Ixscode -c BibTeX.c -o BibTeX.o
      $CC -O2 ${winXsCflags} -I"$CORE" -Ibtparse/src -Ixscode -c xscode/btxs_support.c -o btxs_support.o
      $AR cr BibTeX.a BibTeX.o btxs_support.o )
    ALLA="$ALLA bibtex/BibTeX.a bibtex/libbtparse.a"; EXTS="$EXTS Text/BibTeX"

    # ===== (3) XML::LibXML (+ static mingw libxml2) =====
    mkdir -p libxml && tar xf "$XMLLIBXML_SRC" -C libxml --strip-components=1
    ( cd libxml
      for xs in LibXML Devel; do
        $PERL -MExtUtils::ParseXS -e \
          'ExtUtils::ParseXS->new->process_file(filename=>$ARGV[0].".xs", output=>$ARGV[0].".c", typemap=>["'"$TYPEMAP"'","'"$PWD"'/typemap"])' $xs
      done
      for c in LibXML Devel dom perl-libxml-mm perl-libxml-sax xpath Av_CharPtrPtr; do
        $CC -O2 ${winXsCflags} $XML2_CF -DHAVE_UTF8 -I"$CORE" -I. -c "$c.c" -o "$c.o"
      done
      $AR cr LibXML.a LibXML.o Devel.o dom.o perl-libxml-mm.o perl-libxml-sax.o xpath.o Av_CharPtrPtr.o )
    ALLA="$ALLA libxml/LibXML.a"; EXTS="$EXTS XML/LibXML XML/LibXML/Devel"

    # ===== (4) XML::LibXSLT (+ static mingw libxslt/libexslt, shares libxml2) =====
    mkdir -p libxslt && tar xf "$XMLLIBXSLT_SRC" -C libxslt --strip-components=1
    ( cd libxslt
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"LibXSLT.xs", output=>"LibXSLT.c", typemap=>["'"$TYPEMAP"'","'"$PWD"'/typemap"])'
      for c in LibXSLT perl-libxml-mm; do
        $CC -O2 ${winXsCflags} $XML2_CF $XSLT_CF -I"$CORE" -I. -c "$c.c" -o "$c.o"
      done
      $AR cr LibXSLT.a LibXSLT.o perl-libxml-mm.o )
    ALLA="$ALLA libxslt/LibXSLT.a"; EXTS="$EXTS XML/LibXSLT"

    # ===== (5) Unicode::LineBreak (+ bundled sombok) =====
    mkdir -p linebreak && tar xf "$LINEBREAK_SRC" -C linebreak --strip-components=1
    ( cd linebreak
      $PERL -I. Makefile.PL PERL="$BPERL" FULLPERL="$BPERL" >/dev/null
      ( cd sombok
        $PERL Makefile.PL PERL="$BPERL" FULLPERL="$BPERL" >/dev/null
        make -j$NIX_BUILD_CORES CC="$CC" LD="$CC" AR="$AR" OPTIMIZE="-O2" >/dev/null )
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"LineBreak.xs", output=>"LineBreak.c", typemap=>["'"$TYPEMAP"'","'"$PWD"'/typemap"])'
      $CC -O2 ${winXsCflags} -DVERSION='"2019.001"' -DXS_VERSION='"2019.001"' -I"$CORE" -Isombok/include -I. -c LineBreak.c -o LineBreak.o
      $AR cr LineBreak.a LineBreak.o )
    ALLA="$ALLA linebreak/LineBreak.a $(find linebreak/sombok -name 'libsombok*.a' | head -1)"; EXTS="$EXTS Unicode/LineBreak"

    # ===== (6) Params::Validate (Build.PL bypass) =====
    mkdir -p params && tar xf "$PARAMSVALIDATE_SRC" -C params --strip-components=1
    ( cd params
      $PERL -MExtUtils::ParseXS -e \
        'ExtUtils::ParseXS->new->process_file(filename=>"lib/Params/Validate/XS.xs", output=>"PV_XS.c", typemap=>["'"$TYPEMAP"'"])'
      $CC -O2 ${winXsCflags} -DVERSION='"1.31"' -DXS_VERSION='"1.31"' -I"$CORE" -Ic -Ilib/Params/Validate -c PV_XS.c -o PV_XS.o
      $AR cr PV_XS.a PV_XS.o )
    ALLA="$ALLA params/PV_XS.a"; EXTS="$EXTS Params/Validate/XS"

    # ===== VFS objects + dispatch + the @INC blob =====
    $CC -O2 -std=gnu17 -I${./src} -c ${./src/vfs_miniz.c} -o vfs.o
    $CC -O2 -std=gnu17 -I${./src} -c ${./src/miniz.c} -o miniz.o
    $CC -O2 -std=gnu17 -c ${./src/dispatch.c} -o dispatch.o

    # Stage @INC: every `use lib` tree from the build-host biber driver under
    # /zip/inc/NNN (arch subdirs keyed on the build-host archname, where the
    # staged .pm physically live) + the win perl stdlib under /zip/inc/perl.
    mkdir -p stage/inc stage/bin
    PERLVER="$($PERL -MConfig -e 'print $Config{version}')"
    ARCHB="MSWin32-x64"
    BARCHB="$($BPERL -MConfig -e 'print $Config{archname}')"
    i=0; INCEXPR=""
    for p in $($PERL -ne 'if(/^use lib (.*);\s*$/){my$l=$1;while($l=~/"([^"]+)"/g){print "$1\n"}}' ${biber}/bin/biber); do
      d=$(printf '%03d' $i)
      mkdir -p "stage/inc/$d"; cp -r "$p"/. "stage/inc/$d"/ 2>/dev/null || true
      for sub in "" "/$BARCHB" "/$PERLVER" "/$PERLVER/$BARCHB"; do
        [ -d "$p$sub" ] && INCEXPR="$INCEXPR\"/zip/inc/$d$sub\","
      done
      i=$((i+1))
    done
    # win perl stdlib (privlib carries the MSWin32-x64 arch subdir).
    mkdir -p stage/inc/perl
    cp -r "${winPerl}/lib/perl5/5.42.0"/. stage/inc/perl/
    # Win32.pm so `require Win32` resolves at runtime (its bootstrap finds the
    # statically-linked boot_Win32, installing GetCwd/GetFullPathName as XSUBs).
    cp win32mod/Win32.pm stage/inc/perl/Win32.pm
    # perl-cross's -Uusedl winPerl omits core .pm the static boot makes redundant
    # (notably DynaLoader.pm), but modules still `require DynaLoader` -- Win32.pm
    # does at compile time. Fill gaps from the build-host perl's archlib into the
    # staged target arch dir, no-clobber so the target's own arch files (Config*)
    # win. Dev leftovers (auto/, CORE/, *.a/.h) are scrubbed just below. (Same fix
    # the linux cross applies in flake.nix.)
    chmod -R u+w "stage/inc/perl/$ARCHB"
    cp -rn "$BARCH_B"/. "stage/inc/perl/$ARCHB"/ 2>/dev/null || true
    INCEXPR="$INCEXPR\"/zip/inc/perl\",\"/zip/inc/perl/$ARCHB\""
    chmod -R u+w stage
    # biber's own bundled data files live in the linker VFS (/zip), and Biber::
    # Utils routes slurp/stat/exists through Win32::Unicode::File whenever the
    # Windows ANSI code page isn't UTF-8. But Win32::Unicode calls CreateFileW
    # directly, which only sees the real FS -- it can't read /zip (that namespace
    # is served by our __wrap_win32_* VFS, which only perl's own win32_* I/O hits).
    # So biber dies opening e.g. /zip/.../Biber/LaTeX/recode_data.xml. Carve /zip
    # paths out of the Win32 branch in all five gated subs (slurp_switchr/w,
    # file_exist_check, check_empty, check_exists -- each takes $filename): for a
    # /zip path the condition is now false, so it falls through to File::Slurper /
    # -e, which open via perl -> the VFS. Real user files still take the Win32::
    # Unicode path, so non-ASCII filenames keep working. (After chmod -R u+w: the
    # staged trees come read-only from the store, so sed -i needs the dirs writable.)
    find stage/inc -path '*Biber/Utils.pm' | while read -r u; do
      sed -i 's|and not is_Unicode_system() ) {|and not is_Unicode_system() and $filename !~ m{^[/\\\\]zip[/\\\\]} ) {|g' "$u"
    done
    # Windows-only pure-Perl deps missing from the linux closure (see let binding).
    SQ="$(find ${win32ShellQuote} -name 'ShellQuote.pm' -path '*Win32*' | head -1)"
    mkdir -p stage/inc/perl/Win32
    cp "$SQ" stage/inc/perl/Win32/ShellQuote.pm
    # Win32::Unicode pure-Perl tree (File.pm + the modules it pulls: Util/Error/
    # Constant/Console/Dir + the Unicode.pm umbrella). The XS above is registered
    # statically; these .pm drive it. Arch-independent, staged into the blob.
    cp w32u/lib/Win32/Unicode.pm stage/inc/perl/Win32/Unicode.pm
    cp -r w32u/lib/Win32/Unicode stage/inc/perl/Win32/
    # Encode::Unicode .pm (the XS above is registered statically; this drives it).
    # winPerl staged Encode/ (Config.pm etc.) but not Unicode.pm, so add it.
    mkdir -p stage/inc/perl/Encode
    cp encu/Unicode/Unicode.pm stage/inc/perl/Encode/Unicode.pm
    find stage/inc -type f \( -name '*.so' -o -name '*.dll' -o -name '*.a' -o -name '*.h' -o -name '*.ld' -o -path '*/CORE/*' \) -delete
    find stage/inc -depth -type d -empty -delete 2>/dev/null || true
    find stage/inc -name 'Config_heavy.pl' -o -name 'Config.pm' | while read -r f; do
      sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
    done
    {
      echo "#!/zip/bin/perl"
      # Load Win32 right after @INC is set, before any module pulls in Cwd: Cwd
      # binds its MSWin32 cwd implementation at compile time based on whether
      # Win32::GetCwd is already defined. Loading Win32 first => native, no
      # `cmd /c cd` shell-out per cwd lookup (the startup hang).
      echo "BEGIN { @INC = ($INCEXPR); require Win32; }"
      # Drop the driver's `use FindBin; use lib $FindBin::RealBin;`. FindBin
      # resolves the script dir with Cwd::abs_path($0), which on MSWin32 is the
      # generic stat-walking fast_abs_path (no XS abs_path like POSIX) -- it
      # never terminates on the virtual /zip path, so biber would spin forever
      # stat-ing /zip/bin/. @INC is already fully pinned above, so adding
      # $FindBin::RealBin (=/zip/bin, no modules there) is redundant anyway, and
      # no Biber module references $FindBin. (Linux keeps it: XS abs_path resolves
      # /zip cleanly. Biber::Config's abs_path calls are on real-FS config paths.)
      tail -n +3 ${biber}/bin/biber \
        | sed -E '/^use FindBin;/d; /^use lib \$FindBin::RealBin;/d'
    } > stage/bin/biber

    ( cd stage && zip -9 -X -r -q ../incblob inc bin )
    [ -f incblob ] || mv incblob.zip incblob
    cp ${./src/blob_win.S} blob.S
    $CC -c blob.S -o incblob.o

    # ===== relink: perl.exe + 19 XS static-ext + VFS + blob + dispatch =====
    # win32 syslibs the .exe needs (from the target Config) + each kept core
    # ext's extralibs.ld; skip Compress/Raw/* (their extralibs point at the cross
    # zlib/bzip2 DLL import libs -> would need a DLL at runtime).
    SYSLIBS="$(sed -nE "s/^perllibs='(.*)'/\1/p" "$ARCH/Config_heavy.pl")"
    COREEXTS=""; COREA=""; EXTRALIBS=""
    for a in $(find "$ARCH/auto" -name '*.a'); do
      case "$a" in *auto/Compress/Raw/*) continue;; esac
      ext="$(echo "$a" | sed -E 's|.*/auto/||; s|/[^/]*\.a$||')"
      COREEXTS="$COREEXTS $ext"; COREA="$COREA $a"
      el="$(dirname "$a")/extralibs.ld"
      [ -f "$el" ] && EXTRALIBS="$EXTRALIBS $(cat "$el")"
    done
    $PERL -MExtUtils::Miniperl -e 'writemain(@ARGV)' $COREEXTS $EXTS > perlmain.c
    $CC -O2 ${winXsCflags} -I"$CORE" -c perlmain.c -o perlmain.o
    # static libxml2 also pulls zlib (compression), GNU libiconv (encoding) and
    # the win32 bcrypt.dll (BCryptGenRandom, used to seed the dict hash) -> link
    # the static .a's plus -lbcrypt (a system DLL import lib, always present).
    Z_A="$(find ${msc.zlib.out or msc.zlib}/lib -name 'libz.a' | head -1)"
    ICONV_A="$(find ${msc.libiconv}/lib -name 'libiconv.a' | head -1)"
    WRAP="-Wl,--wrap=win32_open -Wl,--wrap=win32_stat -Wl,--wrap=win32_lstat -Wl,--wrap=win32_access -Wl,--wrap=main"
    $CC -O2 -o biber.exe $WRAP \
      perlmain.o vfs.o miniz.o dispatch.o incblob.o \
      $ALLA $COREA "$EXSLT_A" "$XSLT_A" "$XML2_A" "$Z_A" "$ICONV_A" \
      "$CORE/libperl.a" -Wl,--allow-multiple-definition \
      $SYSLIBS $EXTRALIBS ${mcfA}/libmcfgthread.a -lbcrypt -luserenv -lwinhttp
    file biber.exe
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp biber.exe $out/bin/biber.exe
    runHook postInstall
  '';
}
