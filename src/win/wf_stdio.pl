my $f=shift; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
$s =~ s/^stdio_ptr=.*$/stdio_ptr='PERLIO_FILE_ptr(fp)'/m or die "stdio_ptr not in $f";
$s =~ s/^stdio_cnt=.*$/stdio_cnt='PERLIO_FILE_cnt(fp)'/m or die "stdio_cnt not in $f";
$s =~ s/^stdio_base=.*$/stdio_base='PERLIO_FILE_base(fp)'/m or die "stdio_base not in $f";
$s =~ s/^stdio_bufsiz=.*$/stdio_bufsiz='(PERLIO_FILE_cnt(fp) + PERLIO_FILE_ptr(fp) - PERLIO_FILE_base(fp))'/m or die "stdio_bufsiz not in $f";
open my $o,'>',$f or die; print $o $s; close $o;
