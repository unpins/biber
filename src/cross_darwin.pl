#!/usr/bin/env perl
# perl-cross Mach-O-build-host fixups for the unpins single-binary VFS build.
#
# perl-cross has no darwin support (cnf/hints/ ships only android/gnu/linux/
# midipix/mswin32/netbsd/nto) and assumes an ELF *build host*: it determines
# type sizes by reading `readelf --syms` and byte order by reading `objdump`,
# and `die`s outright if either tool is missing. On a darwin build host (the
# x86_64-darwin <-> aarch64-darwin cross) there is no ELF readelf/objdump and a
# Mach-O object can't be read by one anyway, so `configure --mode=buildmini`
# dies at "Cannot find readelf" before it ever gets going.
#
# Both probes have a compile-only, cross-safe equivalent that needs neither a
# readelf nor a run (so it's correct for the buildmini *and* the target pass,
# x86_64 and arm64 alike):
#   - sizeof  -> negative-array trick: `int p[(sizeof(T)==K)?1:-1];` compiles
#                only when K is the real size; bisect K.
#   - byteorder -> the preprocessor's __BYTE_ORDER__, which under the cross
#                compiler already reflects the target.
# We also drop the two `|| die` guards so a missing readelf/objdump is no longer
# fatal (they are never called after these rewrites).
#
# Runs in postPatch for the darwin cross only; perl-cross is laid into the perl
# source tree by nixpkgs' postUnpack (`cp -R perl-cross/* perl-<ver>/`), so its
# cnf/ scripts are plain files here. Linux crosses keep the stock readelf path
# (their build host is ELF), so this is darwin-gated by the caller.
use strict;
use warnings;

sub slurp { open my $h, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$h>; close $h; $s }
sub spew  { open my $h, '>', $_[0] or die "$_[0]: $!"; print $h $_[1]; close $h }

sub replace {
    my ($file, $old, $new, $what) = @_;
    my $s = slurp($file);
    my $i = index($s, $old);
    die "cross_darwin: anchor not found ($what in $file)\n" if $i < 0;
    substr($s, $i, length($old)) = $new;
    spew($file, $s);
}

# 1) cnf/configure_tool.sh -- make readelf/objdump non-fatal (never called below)
replace(
    'cnf/configure_tool.sh',
    qq{whichprog readelf READELF readelf || die "Cannot find readelf"\n}
        . qq{whichprog objdump OBJDUMP objdump || die "Cannot find objdump"\n},
    qq{whichprog readelf READELF readelf || true\n}
        . qq{whichprog objdump OBJDUMP objdump || true\n},
    'readelf/objdump die guards',
);

# 2) cnf/configure_type.sh -- replace the readelf-based checksize body with a
#    compile-only bisection.
replace(
    'cnf/configure_type.sh',
    join('',
        "\tif not try_readelf --syms > try.out 2>>\$cfglog; then\n",
        "\t\tresult 'unknown'\n",
        "\t\tdie \"Cannot determine sizeof(\$2), use -D\${1}size=\"\n",
        "\t\treturn\n",
        "\tfi\n",
        "\n",
        "\tresult=`grep foo try.out | sed -r -e 's/.*: [0-9]+ +//' -e 's/ .*//' -e 's/^0+//g'`\n",
        "\tif [ -z \"\$result\" ]; then\n",
        "\t\tresult \"unknown\"\n",
        "\t\tdie \"Cannot determine sizeof(\$2)\"\n",
        "\telif [ \"\$result\" -gt 0 ]; then\n",
        "\t\tdefine \$1 \"\$result\"\n",
        "\t\tresult \$result\\ `bytes \$result`\n",
        "\telse\n",
        "\t\tresult \"unknown\"\n",
        "\t\tdie \"Cannot determine sizeof(\$2)\"\n",
        "\tfi\n",
    ),
    join('',
        "\t# unpins darwin cross: no ELF readelf on a Mach-O build host -- size\n",
        "\t# via a compile-only probe (cross-safe for buildmini and target).\n",
        "\t__cssz=0\n",
        "\tfor __csk in 1 2 4 8 12 16 3 6 10 5 7 9 11 13 14 15; do\n",
        "\t\ttry_start\n",
        "\t\ttry_includes \$3\n",
        "\t\ttry_add \"int _csprobe[(sizeof(\$2)==\$__csk)?1:-1];\"\n",
        "\t\tif try_compile; then __cssz=\$__csk; break; fi\n",
        "\tdone\n",
        "\tif [ \"\$__cssz\" -gt 0 ]; then\n",
        "\t\tdefine \$1 \"\$__cssz\"\n",
        "\t\tresult \$__cssz\\ `bytes \$__cssz`\n",
        "\telse\n",
        "\t\tresult \"unknown\"\n",
        "\t\tdie \"Cannot determine sizeof(\$2)\"\n",
        "\tfi\n",
    ),
    'checksize readelf body',
);

# 3) cnf/configure_tool.sh -- teach the OS guesser about darwin. perl-cross has
#    no `*darwin*` case, so osname comes out empty ("Trying to guess target OS
#    ... no"), which (a) is wrong for $^O and (b) stops the hint auto-selector
#    from ever finding cnf/hints/darwin (it keys on $osname).
replace(
    'cnf/configure_tool.sh',
    join('',
        "\t\t*-midipix*)\n",
        "\t\t\tdefine osname \"midipix\"\n",
        "\t\t\tresult \"Midipix\"\n",
        "\t\t\t;;\n",
        "\t\t*)\n",
    ),
    join('',
        "\t\t*-midipix*)\n",
        "\t\t\tdefine osname \"midipix\"\n",
        "\t\t\tresult \"Midipix\"\n",
        "\t\t\t;;\n",
        "\t\t*darwin*)\n",
        "\t\t\tdefine osname \"darwin\"\n",
        "\t\t\tresult \"Darwin\"\n",
        "\t\t\t;;\n",
        "\t\t*)\n",
    ),
    'osname darwin case',
);

# 3b) cnf/configure_tool.sh -- shared-object naming and link flags. perl-cross
#     hard-`define`s these to ELF/GNU values *before* hints run (and before
#     osname is guessed), so a hint can't override them: ccdlflags='-Wl,-E'
#     makes the final `perl` link pass -Wl,-E, which Apple ld rejects ("unknown
#     option: -E"). $targetarch is already known here, so branch on it to use
#     the darwin values (matching perl's own hints/darwin.sh).
replace(
    'cnf/configure_tool.sh',
    join('',
        "define so 'so'\n",
        "define _exe ''\n",
        "\n",
        "# Used only for modules\n",
        "define cccdlflags '-fPIC -Wno-unused-function'\n",
        "define ccdlflags '-Wl,-E'\n",
        "\n",
        "# Misc flags setup\n",
        "predef lddlflags \"-shared\"\t# modules\n",
    ),
    join('',
        "# unpins darwin cross: Mach-O wants different shared-object naming and\n",
        "# link flags than the ELF/GNU defaults; \$targetarch is known here (osname\n",
        "# is guessed later) and is *darwin* for both the buildmini and target pass.\n",
        "case \"\$targetarch\" in\n",
        "*darwin*)\n",
        "\tdefine so 'dylib'\n",
        "\tdefine _exe ''\n",
        "\tdefine cccdlflags '-fPIC -Wno-unused-function'\n",
        "\tdefine ccdlflags ''\n",
        "\tpredef lddlflags \"-bundle -undefined dynamic_lookup\"\n",
        "\t;;\n",
        "*)\n",
        "\tdefine so 'so'\n",
        "\tdefine _exe ''\n",
        "\n",
        "\t# Used only for modules\n",
        "\tdefine cccdlflags '-fPIC -Wno-unused-function'\n",
        "\tdefine ccdlflags '-Wl,-E'\n",
        "\n",
        "\t# Misc flags setup\n",
        "\tpredef lddlflags \"-shared\"\t# modules\n",
        "\t;;\n",
        "esac\n",
    ),
    'shared-object/link flags',
);

# 3c) cnf/configure_misc.sh -- dlext. perl-cross hard-`define`s 'so'; darwin
#     loadable objects are .bundle. Same $targetarch branch.
replace(
    'cnf/configure_misc.sh',
    "define dlext 'so'\n",
    join('',
        "case \"\$targetarch\" in\n",
        "*darwin*) define dlext 'bundle' ;;\n",
        "*) define dlext 'so' ;;\n",
        "esac\n",
    ),
    'dlext',
);

# 3d) Makefile -- perl-cross's static Makefile hard-codes `perl$x: LDFLAGS +=
#     -Wl,-E` (GNU export-dynamic) as a target-specific rule, independent of
#     config.sh/hints, so the final `perl` link always passes -Wl,-E -- which
#     Apple ld rejects ("unknown option: -E"). Use the darwin spelling
#     (-export_dynamic) so dlopen'd XS .bundles can still resolve perl's symbols
#     from the main binary. (The two sibling -Wl,-rpath/-soname rules are gated
#     on a shared libperl, which the static single-binary build never produces.)
replace(
    'Makefile',
    "perl\$x: LDFLAGS += -Wl,-E\n",
    "perl\$x: LDFLAGS += -Wl,-export_dynamic\n",
    'perl link -Wl,-E',
);

# 4) cnf/hints/darwin -- perl-cross ships hints only for android/gnu/linux/
#    midipix/mswin32/netbsd/nto. The hints supply the "non-testable" values
#    perl-cross can't probe without running a target binary (syscall presence,
#    signal return type, st_ino shape, ...). Without them every such config var
#    is empty and config_h.SH emits a malformed `#  HAS_FOO` line (the build
#    dies at the first one, HAS_NANOSLEEP). This mirrors cnf/hints/linux with
#    darwin-correct values; the auto-selector loads it once osname=darwin, in
#    both the buildmini and target passes.
spew('cnf/hints/darwin', <<'HINT');
# Darwin (macOS) -- unpins perl-cross port. Values perl-cross cannot probe
# without running a target binary; mirrors cnf/hints/linux, darwin-corrected.
d_voidsig='define'
d_nanosleep='define'
d_clock_gettime='define'
d_clock_getres='define'
d_clock_nanosleep='undef'
d_clock='define'

usemallocwrap='define'

# libraries to test (everything else lives in libSystem)
libswanted='m pthread'

# macOS has no /proc; perl uses _NSGetExecutablePath instead.
d_procselfexe='undef'

# ino_t is an unsigned 64-bit __darwin_ino64_t
st_ino_sign=1
st_ino_size=8

d_fcntl_can_lock='define'
HINT

# 5) cnf/configure_type_sel.sh -- byte order from the preprocessor, not objdump.
replace(
    'cnf/configure_type_sel.sh',
    join('',
        "\tif try_compile && try_objdump -j .data -j .sdata -s; then\n",
        "\t\tbo=`grep '11' try.out | grep '44' | sed -e 's/  .*//' -e 's/[^1-8]//g' -e 's/\\([1-8]\\)\\1/\\1/g'`\n",
        "\telse\n",
        "\t\tbo=''\n",
        "\tfi\n",
    ),
    join('',
        "\t# unpins darwin cross: derive byte order from the preprocessor\n",
        "\t# (__BYTE_ORDER__ reflects the target under the cross compiler);\n",
        "\t# no objdump on Mach-O. Correct for both buildmini and target.\n",
        "\ttry_start\n",
        "\ttry_includes \"stdint.h\" \"sys/types.h\"\n",
        "\ttry_add \"int _beprobe[(__BYTE_ORDER__==__ORDER_LITTLE_ENDIAN__)?1:-1];\"\n",
        "\tif try_compile; then\n",
        "\t\tif [ \"\$uvsize\" = 8 ]; then bo=12345678; else bo=1234; fi\n",
        "\telse\n",
        "\t\tif [ \"\$uvsize\" = 8 ]; then bo=87654321; else bo=4321; fi\n",
        "\tfi\n",
    ),
    'byteorder objdump body',
);

print "cross_darwin: perl-cross Mach-O-host probes patched\n";
