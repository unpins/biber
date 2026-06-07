#!/usr/bin/env bash
# Spike-trimmed winfix: turn a perl-cross-configured tree into a real win32-native
# target, WITHOUT the unpins VFS (@INC stays the real install tree, not /zip). This
# is a stripped copy of unpins/perl/src/win/winfix.sh keeping only the bits needed
# to make the interpreter build+run win32-native (overlay config.gc OS/ABI vars,
# wire win32/*.c into libperl, stdio/flags/errno/HiRes, exe suffix). The /zip @INC
# pin, sitecustomize, UNPIN_VFS_FIXED_INC and the inc-macro patch are dropped --
# the spike points @INC via PERL5LIB/-I like the linux/darwin proofs.
#
# Usage: winfix-spike.sh <wfdir> <mcfstatic-libdir>   ($NPERL = native build perl)
set -e
W="$(pwd)"
WFDIR="$1"
MCF="$2"
: "${NPERL:?NPERL (native perl) must be set}"
GCSRC="$W/win32/config.gc"

# 1) Overlay win32-canonical OS/ABI capability vars from config.gc onto config.sh
#    (fixes missing d_* like d_nanosleep -> bare `#HAS_NANOSLEEP` invalid directive).
"$NPERL" "$WFDIR/wf_overlay.pl" "$GCSRC" config.sh

# 2) Force win32 ABI int types + exe suffix (mingw appends .exe to the suffix-less
#    `perl$x` link target). No usesitecustomize, no /zip *exp (spike uses real @INC).
setv(){ local k="$1" v="$2"; if grep -q "^$k=" config.sh; then WF_K="$k" WF_V="$v" "$NPERL" -i -pe 's/^\Q$ENV{WF_K}\E=.*/"$ENV{WF_K}=$ENV{WF_V}"/e' config.sh; else echo "$k=$v" >> config.sh; fi; }
setv i32type long
setv u32type "'unsigned long'"
setv i16type short
setv u16type "'unsigned short'"
setv i8type char
setv u8type "'unsigned char'"
setv longdblsize 16
setv sizesize 8
setv _exe "'.exe'"
setv exe_ext "'.exe'"

# 2b) Canonical win32 signal table from config.gc. perl-cross derives a SPARSE,
#     count-sized table for the mingw target (sig_size=7, sig_name='ZERO INT ILL
#     ABRT FPE SEGV TERM', sig_num='0 2 4 22 8 11 15'). But perl indexes
#     PL_psig_ptr by signal NUMBER while allocating it to SIG_SIZE slots, so a
#     read of $SIG{TERM} (15) or $SIG{ABRT} (22) runs off the 7-slot array into
#     heap garbage -> magic_getsig's sv_setsv hits a bogus SV ("Bizarre copy of
#     HASH/UNKNOWN", or an intermittent ~null deref crash, depending on what's in
#     the heap). Only INT(2)/ILL(4) stay in bounds, which is why it's flaky rather
#     than total. config.gc carries the DENSE, index-aligned table real Windows
#     perl ships (sig_size=27, covering ABRT=22/CONT=25), so copy it verbatim.
#     wf_overlay.pl skips sig_* on purpose (its allow-list is d_*/i_*/*format),
#     so set them explicitly here; config_h.SH (step 6) then bakes SIG_NAME/
#     SIG_NUM/SIG_SIZE into config.h and the build picks them up for Config too.
for k in sig_name sig_num sig_size sig_name_init sig_num_init; do
  v="$(sed -nE "s/^$k=(.*)\$/\1/p" "$GCSRC")"
  [ -n "$v" ] && setv "$k" "$v"
done

# 3) stdio FILE accessors -> safe PERLIO_FILE_* (matches official win32 config.h)
"$NPERL" "$WFDIR/wf_stdio.pl" config.sh

# 4) ccflags/ldflags/libs: win32 host-layer includes (absolute), static mcfgthread,
#    win32 syslibs.
"$NPERL" "$WFDIR/wf_flags.pl" config.sh "$W" "$MCF"

# 4b) perl-cross Makefile: add win32 host objs to TARGET libperl (+ static pm_to_blib)
"$NPERL" "$WFDIR/wf_makefile.pl" Makefile

# 4c) Time::HiRes: honor TARGET osname for the win32 (skip-probe) branch
"$NPERL" "$WFDIR/wf_timehires.pl" dist/Time-HiRes/Makefile.PL

# 4d) Errno: honor TARGET osname (use mingw errno.h, not host /usr/include)
"$NPERL" "$WFDIR/wf_errno.pl" ext/Errno/Errno_pm.PL

# 5) win32 host-layer: Win32iop.h case-insensitive symlink (Linux is case-sensitive)
ln -sf win32iop.h win32/Win32iop.h

# 6) regenerate config.h, xconfig.h, Makefile.config from fixed config.sh
rm -f config.h xconfig.h Makefile.config
CONFIG_H=config.h  CONFIG_SH=config.sh  ./config_h.SH  >/dev/null 2>&1
CONFIG_H=xconfig.h CONFIG_SH=xconfig.sh ./config_h.SH >/dev/null 2>&1
make Makefile.config >/dev/null 2>&1
echo "winfix-spike applied. CFLAGS:"; grep '^CFLAGS' Makefile.config
