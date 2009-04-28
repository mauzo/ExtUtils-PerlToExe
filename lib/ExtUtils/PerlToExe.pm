package ExtUtils::PerlToExe;

=head1 NAME

ExtUtils::PerlToExe - Create perl executables for specific programs.

=head1 DESCRIPTION

This module converts a Perl program into a binary executable. Unlike
L<PAR>, it doesn't do so by effectively creating a self-extracting ZIP;
instead, it builds a custom embedded perl interpreter that will only run
the supplied program.

Currently the binary still depends on F<libperl.so> and requires a full
C<@INC> tree on disc, but I hope to remove that restriction once I've
worked out how MakeMaker's C<make perl> works C<:)>.

=head1 FUNCTIONS

=cut

use 5.010;

use warnings;
use strict;

use version; our $VERSION = '0.01';

use Exporter::NoWork;

use Config;
use ExtUtils::Miniperl  ();
use ExtUtils::Embed     ();

use List::Util          qw/max/;
use File::Temp          qw/tempdir/;
use File::Slurp         qw/read_file write_file/;
use IPC::System::Simple qw/system/;
use File::Copy          qw/cp/;
use File::Spec::Functions   qw/devnull/;
use File::ShareDir      qw/dist_file/;

my $DIST = "ExtUtils-PerlToExe";

=head2 perlmain

Returns the text of F<perlmain.c>, from L<ExtUtils::Miniperl>.

=cut

sub perlmain {
    open my $MAIN, ">", \my $C;
    my $OLD = select $MAIN;
    ExtUtils::Miniperl::writemain;
    select $OLD;
    close $MAIN;

    return $C;
}

=head2 Cqq [ I<STRING> ]

Escapes I<STRING> suitable for interpolation into a C string. If
I<STRING> is omitted, defaults to C<$_>.

=cut

sub Cqq (_) {
    my $_ = shift;
    s/\\/\\\\/g;
    s/"/\\"/g;
    s/\n/\\n/g;
    s/\0/\\0/g;
    s/([^[:print:]])/sprintf "\\%03o", ord $1/ge;
    $_;
}

=head2 str_to_C [ I<STRING> ]

Converts I<STRING> into a quoted C string. If I<STRING> is omitted,
defaults to C<$_>. This will break the string into separately-quoted
parts, separated by newlines.

=cut

sub str_to_C (_) {
    return 
        join "",
        map qq/\n"$_"/,
        map Cqq,
        map { unpack "(a70)*" }
        split /(?<=[\n\0])/,
        $_[0];
}

=head2 exemain I<LIST>

Returns the text of perlmain.c, modified to run perl with the arguments
passed. I<LIST> should B<not> include C<argv[0]>, as that will passed
from C<main> when the program is invoked. This is necessary as on many
platforms C<$^X> is calculated from e.g. F</proc/self/exe>, and ignores
the passed C<argv[0]>.

Any additional arguments passed to the resulting executable will be
added to C<perl_parse>'s C<argv>, after a C<-->.

=cut

sub exemain {
    my $C = perlmain;
    $C =~ s{#include "perl.h"\n\K}{
        #include "perlapi.h"
        #include "pl2exe.h"
    };
    return $C;
}

sub pl2exe_c {
    my @argv        = @_;

    grep /^--$/, @argv or push @argv, "--";

    my $argc        = @argv + 1;
    my $argv_buf    = str_to_C join "", map "$_\0", @argv;

    my $C = read_file dist_file $DIST, "pl2exe.c";

    $C =~ s/(^ .* \$my_argv_init .* $)/\$my_argv_init/mx;
    my $init_tmpl = $1;
    my $argv_init = "";
    my $ptr       = 0;

    for my $n (1..@argv) {
        given ($init_tmpl) {
            s/\$n/$n/g;
            s/\$ptr/$ptr/g;
            $argv_init .= $_;
        }
        $ptr += 1 + length $argv[$n - 1];
    }

    $ptr++;

    for ($C) {
        s/\$my_argv_init/$argv_init/;
        s/\$len/$ptr/g;
        s/\$argv_buf/$argv_buf/g;
        s/\$argc/$argc/g;
    }


    warn $C;

    return $C;
}

sub mysystem {
    my ($cmd) = @_;
    warn "$cmd\n";
    system $cmd;
}

=head1 build_exe NAME, LIST

Compiles and links a version of perl that runs with the supplied
arguments.

=cut

sub build_exe {
    my ($exe, @argv) = @_;

    my $tmp = tempdir CLEANUP => 1;

    # This is possibly the nastiest interface I have ever seen :).
    # ccopts prints to STDOUT if we're running under -e; ldopts prints
    # to STDOUT if it doesn't get any arguments.

    my $ccopts = do {
        no warnings "redefine";
        local *ExtUtils::Embed::is_cmd = sub { 0 };
        ExtUtils::Embed::ccopts;
    };
    my $ldopts = ExtUtils::Embed::ldopts(1);

    my ($SCRP, $offset);

    for (@argv) {
        /^--$/ and last;
        unless (/^-/) {

            # We supply a fake script argument of /dev/null to
            # perl_parse, then fixup PL_rsfp and PL_scriptname in
            # xsinit.

            my $script = $_;
            $_ = devnull;

            open $SCRP, "<", $script or die "can't read '$script'\n";
            $offset = -s $SCRP
                or die "script file '$script' is empty\n";

            last;
        }
    }

    warn "Generating source...";
    write_file "$tmp/exemain.c", exemain;
    write_file "$tmp/pl2exe.c", pl2exe_c @argv;
    cp dist_file($DIST, "pl2exe.h"), "$tmp/pl2exe.h";
    
    warn "Compiling...\n";
    mysystem qq!$Config{cc} -c $ccopts -o "$tmp/exemain.o" "$tmp/exemain.c"!;
    mysystem qq!$Config{cc} -c $ccopts -o "$tmp/pl2exe.o" "$tmp/pl2exe.c"!;

    my $aout = "$tmp/a" . ($Config{_exe} || ".out");

    warn "Linking...\n";
    mysystem qq!$Config{ld} -o "$aout" "$tmp/exemain.o" "$tmp/pl2exe.o" $ldopts!;

    open my $EXE,  ">:raw", $exe    or die "can't create '$exe': $!\n";
    open my $AOUT, "<:raw", $aout   or die "can't read '$aout': $!\n";
    cp $AOUT, $EXE;

    if ($offset) {
        warn "Appending script...\n";
        cp $SCRP, $EXE;
    }

    close $EXE                      or die "can't write '$exe': $!\n";
    chmod 0755, $exe;
}

1;

=head1 BUGS

Please report bugs to <bug-ExtUtils-PerlToExe@rt.cpan.org>.

=head1 AUTHOR

Ben Morrow <ben@morrow.me.uk>

=head1 COPYRIGHT

Copyright 2009 Ben Morrow.

This program may be distributed under the same terms as perl itself.

