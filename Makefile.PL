use inc::Module::Install;

use warnings;
use strict;

use Config;
use ExtUtils::Embed     qw/ccopts ldopts/;
use ExtUtils::Miniperl  qw/writemain/;
use File::Spec;

name        "ExtUtils-PerlToExe";
all_from    "lib/ExtUtils/PerlToExe.pm";

requires    "version"               => 0;
requires    "Exporter::NoWork"      => "0.02";
requires    "List::Util"            => 0;
requires    "File::Temp"            => 0;
requires    "File::Slurp"           => "9999.09";
requires    "IPC::System::Simple"   => 0;
requires    "File::Copy"            => 0;
requires    "File::Spec"            => 0;
requires    "File::ShareDir"        => 0;
requires    "PerlIO::subfile"       => 0;
requires    "Getopt::Long"          => "2.33";
requires    "Pod::Usage"            => 0;
requires    "Data::Alias"           => 0;
requires    "IPC::Run"              => 0;
requires    "Data::Dump"            => 0;
requires    "Path::Class"           => 0;

install_script  "pl2exe";
install_share;

my $ccopts = ccopts;
my $ldopts = ldopts(1);
my $perlmain = "";
{
    open my $MAIN, ">", \$perlmain;
    my $OLD = select $MAIN;
    writemain ExtUtils::Embed::static_ext;
    select $OLD;
}

open my $LOG, ">", "config.log";

sub wlog {
    $LOG or return;
    local ($,, $\) = ("\n", "\n");
    print $LOG @_;
}

sub mysystem {
    my ($cmd) = @_; 
    wlog $cmd;

    open my $OO, ">&", \*STDOUT;
    open my $OE, ">&", \*STDERR;

    open STDOUT, ">&", $LOG;
    open STDERR, ">&", $LOG;

    my $rv = system $cmd;

    open STDOUT, ">&", $OO;
    open STDERR, ">&", $OE;

    defined $rv and not $rv;
}

sub trymain {
    my ($C) = @_;

    my $src = "perlmain.c";

    {
        open my $MAIN, ">", $src;
        print $MAIN $C;
    }

    my $obj = "perlmain$Config{_o}";

    mysystem qq!$Config{cc} -c -o "$obj" "$src" $ccopts!
        or return;

    my $exe = "a" . ($Config{_exe} || ".out");

    mysystem qq!$Config{ld} -o "$exe" "$obj" $ldopts!
        or return;

    $exe = File::Spec->rel2abs($exe);
    mysystem qq!"$exe" "-MFile::Glob" "-e1"!
        or return;

    return 1;
}

auto_install;

my $config = File::Spec->catfile(qw/share p2econfig.h/);
open my $CONFIG, ">", $config
    or die "can't create '$config': $!\n";

CHECK: {
    print "Checking if your EU::Miniperl works...";
    wlog "Trying perlmain without adding perlapi.h";
    if (trymain $perlmain) {
        print " yes\n";
        last CHECK;
    }

    print " NO\nChecking if adding perlapi.h helps...";
    wlog "Trying perlmain after adding perlapi.h";
    $perlmain =~ s{(\n#include "perl.h"\n)}{$1#include "perlapi.h"\n};
    if (trymain $perlmain) {
        print " yes\n";
        print $CONFIG "#define NEED_PERLAPI_H\n";
        last CHECK;
    }

    print " NO\n";
    die "Your copy of ExtUtils::Miniperl doesn't appear to work properly\n";
}

WriteAll;
