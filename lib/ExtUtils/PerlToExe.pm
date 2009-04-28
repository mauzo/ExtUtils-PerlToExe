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

use warnings;
use strict;

use Exporter::NoWork;

use Config;
use ExtUtils::Miniperl  ();
use ExtUtils::Embed     ();

use List::Util          qw/max/;
use File::Temp          qw/tempdir/;
use File::Slurp         qw/write_file/;
use IPC::System::Simple qw/system/;

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
    my @argv        = (@_, "--");
    my $argc        = @argv + 1;
    my $argv_buf    = str_to_C join "", map "$_\0", @argv;
    my $argv_init   = "";
    my $ptr         = 0;
    my $C           = perlmain;

    for (1..@argv) {
        $argv_init .= "my_argv[$_] = my_argv_buf + $ptr;\n";
        $ptr += 1 + length $argv[$_ - 1];
    }

    $ptr++;

    for ($C) {
        # necessary on Win32 for external linking
        s{#include "perl.h"\K}{\n#include "perlapi.h"};
        s{\*my_perl;\K}{
            static char my_argv_buf[$ptr] = $argv_buf;
        };
        s{\sexitstatus;\K}{
            static int my_argc;
            char *my_argv[$argc + argc];
        };
        s{; \K ( [^;]* perl_parse\( [^)]* ,\s+) argc,\s+ argv,\s+}{
            my_argv[0] = argv[0];
            $argv_init

            /* argv has an extra "\\0" on the end, so we can go all 
               the way up to argv[argc] */

            for (my_argc = 0; my_argc < argc; my_argc++) {
                my_argv[my_argc + $argc] = argv[my_argc + 1];
            }
            my_argc += $argc - 1;

            $1 my_argc, my_argv,
        }x;
    }

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

    write_file "$tmp/exemain.c", exemain @argv;
    
    warn "Compiling...\n";
    mysystem qq!$Config{cc} -c $ccopts -o "$tmp/exemain.o" "$tmp/exemain.c"!;

    warn "Linking...\n";
    mysystem qq!$Config{ld} -o "$exe" "$tmp/exemain.o" $ldopts!;
}

1;

=head1 BUGS

Please report bugs to <bug-ExtUtils-PerlToExe@rt.cpan.org>.

=head1 AUTHOR

Copyright 2009 Ben Morrow <ben@morrow.me.uk>.

This program may be distributed under the same terms as perl itself.

