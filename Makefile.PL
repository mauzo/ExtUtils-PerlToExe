use inc::Module::Install;

use warnings;
use strict;

use Config;
use ExtUtils::Embed         qw/ccopts ldopts/;
use ExtUtils::Miniperl      qw/writemain/;
use File::Spec::Functions   qw/curdir catfile rel2abs updir/;
use Data::Dumper;
use File::Remove            qw/rm/;

include "File::Remove";

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
requires    "PerlIO::gzip"          => 0;
requires    "Getopt::Long"          => "2.33";
requires    "Pod::Usage"            => 0;
requires    "Data::Alias"           => 0;
requires    "Data::Dump"            => 0;
requires    "Path::Class"           => 0;
requires    "Archive::Zip"          => 0;

test_requires   "Test::Builder"     => "0.82";

install_script  "pl2exe";
install_share;

my %P2E = (
    ccopts  => ccopts,
    ldopts  => ldopts(1),
    _exe    => ($Config{_exe} || ".out"),
    include => "-I" . curdir,
    define  => {},
    srcs    => ["exemain", "pl2exe"],
);

open my $LOG, ">", "config.log" or die "can't write config.log: $!\n";
rm \1, "config";
mkdir "config" or die "can't mkdir config: $!\n";

sub config { catfile "config", $_[0] }

sub write_file {
    my ($file, $data) = @_;

    open my $FILE, ">", $file
        or die "can't write $file: $!\n";
    print $FILE $data;
    close $FILE or die "can't write $file: $!\n";
}

sub read_file {
    local $/ = undef;
    open my $FILE, "<", $_[0]
        or die "can't read $_[0]: $!\n";
    <$FILE>;
}

sub cp { write_file $_[1], read_file $_[0] }

{
    open my $MAIN, ">", \(my $perlmain = "");
    my $OLD = select $MAIN;
    my @ext = 
        grep !m!XS/APItest|XS/Typemap!, 
        ExtUtils::Embed::static_ext;
    warn "Writing perlmain with @ext\n";
    writemain @ext;
    select $OLD;
    $perlmain =~ s[(#include "perl.h"\n)][$1#include "pl2exe.h"\n];
    write_file config("exemain.c"), $perlmain;
}

cp catfile("share", $_), config($_)
    for qw/pl2exe.h pl2exe.c Win32CORE.c perlio.c zip.c/;
write_file config($_), ""
    for qw/p2econfig.h subst.h/;

sub wlog {
    $LOG or return;
    local ($,, $\) = ("\n", "\n");
    print $LOG @_;
}

sub mysystem {
    my (@cmd) = @_; 
    wlog join " ", @cmd;

    @cmd == 1 and $cmd[0] =~ s/\n//g;

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

sub NO  { print "NO\n";  chdir updir; return;   }
sub yes { print "yes\n"; chdir updir; return 1; }

sub ddump {
    my ($name, $val) = @_;
    my $D = Data::Dumper->new([$val], ["*$name"]);
    $D->Indent(1);
    $D->Quotekeys(0);
    $D->Dump;
}

sub check {
    my ($msg, $srcs, $argv, $extradef) = @_;

    chdir "config";

    my $define;
    {
        $extradef and local $P2E{define}{$extradef} = 1;

        print "Checking $msg... ";
        wlog "", "Checking $msg, with:", ddump P2E => \%P2E;

        $define = join " ", map "-D$_", keys %{$P2E{define}};
    }
    my $o = $Config{_o};

    for (@$srcs) {
        mysystem <<CMD or NO, return;
$Config{cc} $define $P2E{include} -c -o $_$o $_.c $P2E{ccopts}
CMD
    }

    my @obj = map "$_$o", @$srcs;
    my $exe = "a$P2E{_exe}";

    local $" = " ";
    mysystem <<CMD or NO, return;
$Config{ld} $P2E{ldout}$exe @obj $P2E{ldopts}
CMD

    $exe = rel2abs $exe;
    mysystem $exe, @$argv or NO, return;
   
    $extradef and $P2E{define}{$extradef} = 1;
    yes;
}

sub try {
    my ($c) = @_;
    write_file config("try.c"), $c;
    wlog "", "Creating config/try.c:", $c;
}

CHECK: {
    try <<TRY;
int
main(int argc, char **argv)
{
    return 0;
}
TRY

    for ("-o ", "/out:") {
        $P2E{ldout} = $_;
        check "if your linker uses '$_'", ["try"], []
            and last CHECK;
    }

    die "I can't figure out how to build an executable!\n";
}

my $perl_h = <<H;
#include "EXTERN.h"
#define PERL_IN_MINIPERLMAIN_C
#include "perl.h"
#include "pl2exe.h"
H

{
    try <<TRY;
$perl_h

static PerlInterpreter *my_perl;

int
main(int argc, char **argv) {
    my_perl = perl_alloc();
    if (PL_do_undump)
        return 1;
    return 0;
}
TRY
    
    check "if you can link exported PL_* variables", ["try"], []
        and last;

    check "if perlapi.h helps", ["try"], [], "NEED_PERLAPI_H"
        and last;

    die "I can't link to exported PL_* variables\n";
}

{
    open my $MAIN, ">", \(my $perlmain = "");
    my $OLD = select $MAIN;
    writemain;
    select $OLD;

    my ($xsinit) = $perlmain =~ m!( \n[^\n]+\n xs_init\( .*\n \} )!msx;
    
    try <<TRY;
$perl_h

$xsinit

int
main(int argc, char **argv)
{
    PerlInterpreter *my_perl;
    (void)xs_init(aTHX);
    return 0;
}
TRY

    check "if your compiler can cope with xs_init", 
        ["try"], []
        and last;

    check "if #defining PERL_UNUSED_CONTEXT out helps", 
        ["try"], [], "NEED_NO_PUC"
        and last;

    die "I can't make your compiler compile xs_init.\n";
}

check "if your EU::Miniperl works", 
    $P2E{srcs}, ["-MFile::Glob", "-e1"]
    or die "Your ExtUtils::Miniperl doesn't appear to work properly\n";

{
    defined &Win32::DomainName or last;
    my @args = ($P2E{srcs}, ["-eWin32::DomainName()"]);

    check "if you can call builtin Win32 functions", @args
        and last;

    check "if calling init_Win32CORE helps", @args,
        "NEED_INIT_WIN32CORE"
        and last;

    push @{$P2E{srcs}}, "Win32CORE";
    check "if installing the XSUBs manually helps", @args
        and last;

    warn <<W
!!! Compiled executables will not be able to call builtin Win32
!!! functions without loading Win32.pm.
W
}

{
    my @srcs = (@{$P2E{srcs}}, "zip");
    check "if you can link PerlIO_find_layer", \@srcs, ["-e1"]
        and last;

    check "if we can fake it", [@srcs, "perlio"], ["-e1"]
        and push @{$P2E{srcs}}, "perlio"
        and last;

    die "Can't link PerlIO_find_layer\n";
}

write_file 
    catfile(qw/lib ExtUtils PerlToExe config.pl/), 
    ddump("ExtUtils::PerlToExe::P2EConfig" => \%P2E) . "\n1;\n";

WriteAll;
