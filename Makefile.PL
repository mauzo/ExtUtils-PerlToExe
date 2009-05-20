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

    unless (defined $rv) {
        wlog "execution failed: $!.";
        return;
    }
    if ($rv) {
        wlog "command failed with " . ($rv & 127 ? do {
            require Config;
            my @names = reverse split " ", $Config::Config{sig_name};
            my @nums  = reverse split " ", $Config::Config{sig_num};
            my @sigs;
            $sigs[$nums[$_]] = $names[$_] for 0..$#names;
            "SIG$sigs[$rv & 127]";
        } : ($rv >> 8)) . ".";

        return;
    }
    return 1;
}

sub NO  { print "NO\n";  return;   }
sub yes { print "yes\n"; return 1; }

my %define;

sub check {
    my ($msg, $sym, $argv) = @_;

    my @sym = (@$sym, keys %define);

    print "Checking $msg... ";
    wlog "", "Checking $msg, with:", map("  $_", @sym), ".";

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
    my $pl2exe_c  = File::Spec->catfile("share", "pl2exe.c");
    my $w32core_c = File::Spec->catfile("share", "Win32CORE.c");

    mysystem "$Config{cc} $inc -c -o perlmain$o perlmain.c $ccopts"
        or NO, return;
    mysystem "$Config{cc} $inc -c -o pl2exe$o $pl2exe_c $ccopts"
        or NO, return;

    my @obj = map "$_$o", qw/perlmain pl2exe/;

    if (grep /NEED_FAKE_WIN32CORE/, @sym) {
        mysystem "$Config{cc} $inc -c -o Win32CORE$o $w32core_c $ccopts"
            or NO, return;
        push @obj, "Win32CORE$o";
    }

    my $exe = "a" . ($Config{_exe} || ".out");

    local $" = " ";
    mysystem "$Config{ld} -o $exe @obj $ldopts"
        or NO, return;

    $exe = File::Spec->rel2abs($exe);
    mysystem $exe, @$argv
        or NO, return;
    
    $define{$_} = () for @$sym;
    yes;
}

my $config = File::Spec->catfile(qw/share p2econfig.h/);
if (-e $config) {
    wlog "Unlinking old $config.";
    unlink $config or die "can't remove '$config': $!\n";
}

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
    check "if installing the XSUBs manually helps",
        ["NEED_FAKE_WIN32CORE"], $argv
        and last;

    warn <<W
!!! Compiled executables will not be able to call builtin Win32
!!! functions without loading Win32.pm.
W
}

{
    open my $CONFIG, ">", $config
        or die "can't create '$config': $!\n";
    print $CONFIG map "#define $_\n", keys %define;
}

WriteAll;
