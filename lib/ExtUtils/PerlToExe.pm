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
use File::Slurp         qw/read_file write_file read_dir/;
use IPC::System::Simple qw/system/;
use File::Copy          qw/cp/;
use File::Spec::Functions   qw/devnull/;
use Path::Class         qw/dir file/;
use File::ShareDir      qw/dist_dir dist_file/;
use Data::Alias;

use Data::Dump qw/dump/;

my $DIST = "ExtUtils-PerlToExe";

# this is 'our' for the tests only
our $Verb = 0;

sub _msg {
    my ($v, $msg) = @_;
    $Verb >= $v and warn "$msg\n";
}

=head2 perlmain

Returns the text of F<perlmain.c>, from L<ExtUtils::Miniperl>.

=cut

sub perlmain {
    open my $MAIN, ">", \(my $C = "");
    my $OLD = select $MAIN;

    # Ugh. At least it's a global...
    local %ExtUtils::Miniperl::SEEN;
    my @ext = ExtUtils::Embed::static_ext;
    ExtUtils::Miniperl::writemain @ext;

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
        join "\n",
        map qq/"$_"/,
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
    $C =~ s{#include "perl.h"\n\K}{<<C}e;
#include "perlapi.h"
#include "pl2exe.h"
C
    return $C;
}

sub define {
    my (%macros) = @_;

    return join "", map {
        $macros{$_} =~ s/\n/\\\n/g;
        "#define $_ $macros{$_}\n";
    } keys %macros;
}

sub subst_h {
    my %opts = @_;

    _msg 3, "Writing subst.h with " . dump \%opts;

    alias my @argv = @{$opts{argv}};

    my $ptr = 0;

    my $H = define(
        INIT_MY_ARGV    => 
            "STMT_START {\n" . 
            join("\n", map {
                my $optr = $ptr;
                $ptr += 1 + length $argv[$_ - 1];
                "my_argv[$_] = argv_buf + $optr;";
            } 1..@argv) .
            "\n} STMT_END",

        ARGV_BUF_LEN    => $ptr + 1,
        ARGC            => @argv + 1,
        ARGV_BUF        => str_to_C(join "", map "$_\0", @argv),
        CTL_X           => str_to_C($^X),
    );

    if ($opts{type} eq "append") {
        $H .= define(
            OFFSET      => $opts{offset},
        );
    }

    return $H;
}

sub _mysystem {
    my ($cmd) = @_;
    _msg 2, $cmd;
    system $cmd;
}

=head1 build_exe

Compiles and links a version of perl that runs with the supplied
arguments.

=cut

sub build_exe {
    my %opts = @_;

    $opts{type} ||= $opts{script} ? "append" : "noscript";
    $opts{perl} ||= [];
    $opts{argv} ||= [];

    ref $opts{script} eq "ARRAY"
        and $opts{script} = file @{$opts{script}};

    my $exe = $opts{output} // "a" . ($Config{_exe} || ".out");

    $Verb = $opts{verbose} || 0;

    _msg 3, "Building an exe with " . dump \%opts;

    my $tmp = dir tempdir CLEANUP => 1;

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

    given ($opts{type}) {
        when ("append") {
            # We supply a fake script argument of /dev/null to
            # perl_parse, then fixup PL_rsfp and PL_scriptname in
            # xsinit.

            my $script = $opts{script};
            push @{$opts{perl}}, devnull;

            open $SCRP, "<", $script or die "can't read '$script'\n";
            $offset = -s $SCRP
                or die "script file '$script' is empty\n";
        }
        when ("path") {
            push @{$opts{perl}}, $opts{script};
        }
    }

    _msg 1, "Generating source...";
    my @srcs = read_dir dist_dir $DIST;
    cp dist_file($DIST, $_), $tmp->file($_) for @srcs;

    # File::Slurp doesn't stringify objects properly
    write_file "".$tmp->file("exemain.c"), exemain;
    write_file "".$tmp->file("subst.h"),   subst_h
        type    => $opts{type},
        offset  => $offset,
        argv    => [@{$opts{perl}}, @{$opts{argv}}];

    @srcs = grep s/\.c$//, @srcs;
    push @srcs, qw/exemain/;

    my @objs;
    
    _msg 1, "Compiling...";
    for (@srcs) {
        my $c = $tmp->file("$_.c");
        my $o = $tmp->file("$_$Config{_o}");
        push @objs, $o;
        _mysystem qq!$Config{cc} -c $ccopts -o "$o" "$c"!
    }

    _msg 1, "Linking...";
    local $" = qq/" "/;
    _mysystem 
        qq!$Config{ld} -o "$exe"  "@objs" $ldopts!;

    if ($offset) {
        _msg 1, "Appending script...";
        _msg 2, qq/cat "$opts{script}" >> "$exe"/;

        open my $OUT, ">>:raw", $exe
                            or die "can't append to '$exe': $!\n";
        cp $SCRP, $OUT;
        close $OUT          or die "can't write '$exe': $!\n";
    }

    return 1;
}

1;

=head1 BUGS

Please report bugs to <bug-ExtUtils-PerlToExe@rt.cpan.org>.

=head1 AUTHOR

Ben Morrow <ben@morrow.me.uk>

=head1 COPYRIGHT

Copyright 2009 Ben Morrow.

This program may be distributed under the same terms as perl itself.

