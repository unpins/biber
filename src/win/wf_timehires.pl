my $f=shift; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
my $old = q!        if ($^O =~ /Win32/i) {!;
my $new = q!        if ($^O =~ /Win32/i || $Config{osname} =~ /Win32/i) {!;
$s =~ s/\Q$old\E/$new/ or die "Time::HiRes Win32 test not in $f";
open my $o,'>',$f or die; print $o $s; close $o;
