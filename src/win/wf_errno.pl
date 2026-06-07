my $f=shift; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
# 1) $IsMSWin32 honors target osname
my $a = q[my $IsMSWin32 = $^O eq 'MSWin32';];
my $b = q[my $IsMSWin32 = $^O eq 'MSWin32' || $Config{osname} eq 'MSWin32';];
(index($s,$a)>=0) or die "IsMSWin32 anchor"; $s =~ s/\Q$a\E/$b/;
# 2) main win32 (includes.c) branch keyed off $IsMSWin32, not literal $^O
my $c = q[if ($Config{gccversion} ne '' && $^O eq 'MSWin32') {];
my $d = q[if ($Config{gccversion} ne '' && $IsMSWin32) {];
(index($s,$c)>=0) or die "win32 branch anchor"; $s =~ s/\Q$c\E/$d/;
# 3) don't grab host /usr/include/errno.h when targeting win32
my $e = q[    if ($^O eq 'linux') {];
my $g = q[    if ($^O eq 'linux' && !$IsMSWin32) {];
(index($s,$e)>=0) or die "linux guard anchor"; $s =~ s/\Q$e\E/$g/;
open my $o,'>',$f or die; print $o $s; close $o; print "errno patched\n";
