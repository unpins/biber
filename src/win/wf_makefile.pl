my $f=shift; local $/; open my $h,'<',$f or die; my $s=<$h>; close $h;
my $objline = 'obj = $(patsubst %.c,%$o,$(wildcard $(src)))';
my $win32obj = 'win32obj = win32/win32$o win32/win32sck$o win32/win32thread$o win32/fcrypt$o';
my $libline  = '$(LIBPERL): op$o perl$o $(obj) $(dynaloader_o)';
unless (index($s, "\nwin32obj =") >= 0) {
  my $i = index($s, "\n$objline\n");
  die "obj anchor not found" if $i < 0;
  substr($s, $i + 1 + length($objline), 0) = "\n$win32obj";
}
unless (index($s, $libline.' $(win32obj)') >= 0) {
  my $j = index($s, "\n$libline\n");
  die "libperl anchor not found" if $j < 0;
  substr($s, $j + 1 + length($libline), 0) = ' $(win32obj)';
}
# perl-cross static-module rule builds the .a (target `static`) but skips staging
# the .pm: `static ::` depends only on $(INST_STATIC), not pm_to_blib (only `all`/
# `pure_all` pulls pm_to_blib). Line then `@touch`es the stamp, so make thinks it's
# done and the XS modules' .pm (Storable/Cwd/Data::Dumper/List::Util/...) never reach
# lib/. Fix: also run the module's pm_to_blib target.
my $staticrule = '$(MAKE) -C $(dir $@) PERL_CORE=1 LIBPERL=$(LIBPERL) LINKTYPE=static static';
unless (index($s, $staticrule.' pm_to_blib') >= 0) {
  my $k = index($s, $staticrule."\n");
  die "static_modules rule anchor not found" if $k < 0;
  substr($s, $k + length($staticrule), 0) = ' pm_to_blib';
}
open my $o,'>',$f or die; print $o $s; close $o;
print "makefile: win32obj wired into libperl + static pm_to_blib staged\n";
