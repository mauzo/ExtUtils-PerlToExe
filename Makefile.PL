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

test_requires   "Test::Builder"     => "0.82";

install_script  "pl2exe";
install_share;

my $ccopts = ccopts;
my $ldopts = ldopts(1);
my $perlmain = "";
{
    open my $MAIN, ">", \$perlmain;
    my $OLD = select $MAIN;
    writemain grep !/Win32CORE/, ExtUtils::Embed::static_ext;
    select $OLD;
}
$perlmain =~ s[(#include "perl.h"\n)][$1#include "share/pl2exe.h"\n];
{
    open my $MAIN, ">", "perlmain.c"
        or die "can't write perlmain.c: $!\n";
    print $MAIN $perlmain;
}

open my $LOG, ">", "config.log";

sub wlog {
    $LOG or return;
    local ($,, $\) = ("\n", "\n");
    print $LOG @_;
}

sub mysystem {
    my (@cmd) = @_; 
    wlog join " ", @cmd;

    open my $OO, ">&", \*STDOUT;
    open my $OE, ">&", \*STDERR;

    open STDOUT, ">&", $LOG;
    open STDERR, ">&", $LOG;

    my $rv = system @cmd;

    open STDOUT, ">&", $OO;
    open STDERR, ">&", $OE;

    defined $rv and not $rv;
}

sub NO  { print "NO\n";  return;   }
sub yes { print "yes\n"; return 1; }

my %define;

sub check {
    my ($msg, $sym, $argv) = @_;

    my @sym = (@$sym, keys %define);

    print "Checking $msg... ";
    wlog "Checking $msg, with:", map "  $_", @sym;

    {
        open my $H, ">", "p2econfig.h"
            or die "can't write p2econfig.h: $!\n";
        print $H map "#define $_\n", @sym;
    }
    {
        open my $H, ">", "subst.h"
            or die "can't write subst.h: $!\n";
    }
    my $o = $Config{_o};
    my $inc = "-I" . File::Spec->curdir;
    my $pl2exe_c = File::Spec->catfile("share", "pl2exe.c");

    mysystem "$Config{cc} $inc -c -o perlmain$o perlmain.c $ccopts"
        or NO, return;
    mysystem "$Config{cc} $inc -c -o pl2exe$o $pl2exe_c $ccopts"
        or NO, return;

    my $exe = "a" . ($Config{_exe} || ".out");

    mysystem "$Config{ld} -o $exe perlmain$o pl2exe$o $ldopts"
        or NO, return;

    $exe = File::Spec->rel2abs($exe);
    mysystem $exe, @$argv
        or NO, return;
    
    $define{$_} = () for @$sym;
    yes;
}

auto_install;

{
    my $argv = ["-MFile::Glob", "-e1"];

    check "if your EU::Miniperl works", [], $argv
        and last;
    check "if adding perlapi.h helps", ["NEED_PERLAPI_H"], $argv
        and last;

    die "Your copy of ExtUtils::Miniperl doesn't appear to work properly\n";
}

{
    defined &Win32::DomainName or last;
    my $argv = ["-eWin32::DomainName()"];

    check "if you can call builtin Win32 functions", [], $argv
        and last;
    check "if calling init_Win32CORE helps", ["NEED_INIT_WIN32CORE"],
        $argv
        and last;

    #die "can't work out how to initialize Win32CORE\n";
}

{
    my $config = File::Spec->catfile(qw/share p2econfig.h/);
    open my $CONFIG, ">", $config
        or die "can't create '$config': $!\n";
    print $CONFIG map "#define $_\n", keys %define;
}

WriteAll;
