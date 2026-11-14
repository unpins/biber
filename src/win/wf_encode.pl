# perl-cross lists extensions one directory deep, so Encode's own XS
# sub-extensions (cpan/Encode/{Byte,CN,…}) never make the list: a static perl
# then knows the encoding names but cannot load UTF-16, Shift_JIS, GB2312, …
# Add them as static extensions, and build each after Encode itself.
my ($sh, $mk) = @ARGV;
my @dirs = map "cpan/Encode/$_", qw(Byte CN EBCDIC JP KR Symbol TW Unicode);
my @names = map { (my $n = $_) =~ s!^cpan/!!; $n } @dirs;
local $/; open my $h, '<', $sh or die "$sh: $!"; my $s = <$h>; close $h;
for my $v (qw(static_ext extensions known_extensions)) {
  $s =~ s/^$v='([^']*)'/"$v='" . join(' ', grep length, split(' ', $1), @names) . "'"/me
    or die "$v not in $sh";
}
$s =~ s/^fullpath_static_ext='([^']*)'/"fullpath_static_ext='" . join(' ', grep length, split(' ', $1), @dirs) . "'"/me
  or die "fullpath_static_ext not in $sh";
open my $o, '>', $sh or die; print $o $s; close $o;
open my $m, '>>', $mk or die "$mk: $!";
print $m "\n# wf_encode.pl: Encode's sub-extensions build after Encode\n";
print $m "$_/Makefile: cpan/Encode/pm_to_blib\n" for @dirs;
close $m;
print "encode: ", scalar(@dirs), " sub-extensions added\n";
