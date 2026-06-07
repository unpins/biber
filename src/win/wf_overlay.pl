my ($gc, $sh) = @ARGV;
my %win;
open my $g,'<',$gc or die "gc: $!";
while (<$g>) {
  next if /[~]/;                       # skip toolchain/path placeholder values
  next unless /^([A-Za-z]\w*)=(.*)$/;
  my ($k,$v)=($1,$2);
  # ALLOW: OS capabilities (d_*/i_*), int printf-FORMATs, and a curated derived set.
  # Deliberately NOT *size / *type / byteorder / alignbytes: config.gc's .sh template
  # carries 32-bit defaults (ptrsize=4, BYTEORDER=0x1234, SSize_t=int) that would
  # clobber perl-cross's correctly-detected x64 values -> PTRSIZE=4 = heap corruption.
  my $allow = $k =~ /^(d_|i_)/ || $k =~ /format$/ ||
    $k =~ /^(direntrytype|drand01|randbits|randfunc|randseedtype|seedfunc|signal_t|selecttype|castflags|socksizetype|netdb_host_type|netdb_name_type|netdb_net_type|netdb_hlen_type|db_hashtype|db_prefixtype)$/;
  my $deny = $k =~ /^(cc|ld|ar|nm|cpp|gcc|use.*threads|usemultiplicity|run|targetarch|hostarch|usecrosscompile)/ ||
    $k =~ /^(make|install|prefix|.*lib(pth|s)?$|.*inc$)/;
  $win{$k}=$v if $allow && !$deny;
}
close $g;
delete $win{$_} for qw(usethreads useithreads use5005threads usemultiplicity ccflags optimize lddlflags ldflags so dlext dlsrc usedl libc);
open my $s,'<',$sh or die; my @o; my %seen;
while(<$s>){ if(/^([A-Za-z]\w*)=/ && exists $win{$1}){$seen{$1}=1; push @o,"$1=$win{$1}\n"}else{push @o,$_} }
close $s;
# Append any win32 capability var that the perl-cross config.sh is missing. The
# nixpkgs cross probe set differs from a manual ./configure and omits some d_*
# (e.g. d_nanosleep), which would leave $d_foo empty -> config_h.SH emits a bare
# `#HAS_FOO` (invalid preprocessing directive). config.gc is the canonical win32
# capability set, so its values are the right defaults for any it doesn't carry.
my $added = 0;
for my $k (sort keys %win) {
  next if $seen{$k};
  push @o, "$k=$win{$k}\n"; $added++;
}
open my $w,'>',$sh or die; print $w @o; close $w;
print "overlay: ", scalar(keys %win), " win32 vars applied ($added appended; no size/type clobber)\n";
