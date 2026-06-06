#!/usr/bin/env perl
# perl-cross static-XS .pm staging fix (Linux crosses).
#
# perl-cross builds each static XS module's .a (Makefile target `static`), but its
# `static_modules` recipe depends only on $(INST_STATIC) -- NOT pm_to_blib -- and
# then @touches the per-module stamp, so make believes the module is done. The
# result: the .a (e.g. auto/List/Util/Util.a) is installed, but the module's .pm
# (List/Util.pm, File/Spec.pm + Cwd.pm, Data/Dumper/Dumper.pm, Storable.pm, ...)
# never reach lib/ and so are never installed -> `use List::Util` etc. fail.
#
# Fix: append the module's pm_to_blib target to that recipe so the .pm get staged
# alongside the .a. (The windows backend applies the same fix in wf_makefile.pl,
# bundled with its win32-obj wiring; here it's the portable half on its own.)
use strict;
use warnings;
my $f = shift or die "usage: cross_static_pm.pl <Makefile>\n";
open my $h, '<', $f or die "$f: $!";
local $/;
my $s = <$h>;
close $h;
my $rule = '$(MAKE) -C $(dir $@) PERL_CORE=1 LIBPERL=$(LIBPERL) LINKTYPE=static static';
unless (index($s, $rule . ' pm_to_blib') >= 0) {
    my $k = index($s, $rule . "\n");
    die "static_modules rule anchor not found\n" if $k < 0;
    substr($s, $k + length($rule), 0) = ' pm_to_blib';
}
open my $o, '>', $f or die "$f: $!";
print $o $s;
close $o;
print "cross_static_pm: pm_to_blib staged for static XS modules\n";
