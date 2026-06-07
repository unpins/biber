my ($f,$W,$MCF)=@ARGV; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
my $sys='-lmoldname -lkernel32 -luser32 -lgdi32 -lwinspool -lcomdlg32 -ladvapi32 -lshell32 -lole32 -loleaut32 -lnetapi32 -luuid -lws2_32 -lmpr -lwinmm -lversion -lodbc32 -lodbccp32 -lcomctl32';
my $inc = "-std=gnu17 -fpermissive -DWIN64 -DPERLDLL -I$W/win32 -I$W/win32/include -I$W";
$s =~ s/^ccflags='(.*)'$/ccflags='$1 $inc'/m;
$s =~ s/^ldflags=.*$/ldflags='-L$MCF -Wl,--allow-multiple-definition'/m;
$s =~ s/^libs=.*$/libs='$sys'/m;
$s =~ s/ -E -P/ -E/g;  # official win32 cpprun has no -P (Errno needs #line markers)
$s =~ s/^perllibs=.*$/perllibs='$sys'/m;
open my $o,'>',$f or die; print $o $s; close $o;
