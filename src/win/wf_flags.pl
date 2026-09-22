my ($f,$W,$MCF)=@ARGV; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
# No -lmoldname: that is the msvcrt-era POSIX-alias import lib, which the
# engine's mingw does not ship — and does not need, since its CRT exports
# open/read/getcwd/... under those names itself.
my $sys='-lkernel32 -luser32 -lgdi32 -lwinspool -lcomdlg32 -ladvapi32 -lshell32 -lole32 -loleaut32 -lnetapi32 -luuid -lws2_32 -lmpr -lwinmm -lversion -lodbc32 -lodbccp32 -lcomctl32';
# -fno-strict-aliasing -fwrapv: perl type-puns through its SV/magic unions and
# assumes wrapping signed overflow. perl-cross never adds them (perl's own
# Configure does, from gccversion), and without them the interpreter dies on its
# first module load: "panic: magic_killbackrefs ... warnings.pm".
my $inc = "-std=gnu17 -fpermissive -fno-strict-aliasing -fwrapv -DWIN64 -DPERLDLL -I$W/win32 -I$W/win32/include -I$W";
$s =~ s/^ccflags='(.*)'$/ccflags='$1 $inc'/m;
$s =~ s/^ldflags=.*$/ldflags='-L$MCF -Wl,--allow-multiple-definition'/m;
$s =~ s/^libs=.*$/libs='$sys'/m;
$s =~ s/ -E -P/ -E/g;  # official win32 cpprun has no -P (Errno needs #line markers)
$s =~ s/^perllibs=.*$/perllibs='$sys'/m;
open my $o,'>',$f or die; print $o $s; close $o;
