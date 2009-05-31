package ExtUtils::PerlToExe;

=head1 NAME

ExtUtils::PerlToExe - Build a binary executable from a Perl script.

=head1 DESCRIPTION

This module converts a Perl program into a binary executable. Unlike
L<PAR>, it doesn't do so by effectively creating a self-extracting ZIP;
instead, it builds a custom embedded perl interpreter that will only run
the supplied program.

Currently the binary still depends on F<libperl.so> and requires a full
C<@INC> tree on disc, making this effectively a cleaner replacement for
pl2bat.

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
use File::Copy          ();
use File::Spec::Functions   qw/devnull/;
use Path::Class         qw/dir file/;
use File::ShareDir      qw/dist_dir dist_file/;
use Data::Alias;

use Data::Dump qw/dump/;

my $DIST = "ExtUtils-PerlToExe";

my %P2EConfig = 
    map +(/#define (\w+)/g, 1), 
    read_file dist_file $DIST, "p2econfig.h";

# this is 'our' for the tests only
our $Verb = 0;

sub _msg {
    my ($v, $msg) = @_;
    $Verb >= $v and warn "$msg\n";
}

=begin internals

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

sub exemain {
    my $C = perlmain;
    $C =~ s{#include "perl.h"\n\K}{<<C}e;
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

=head2 subst_h

Returns the text of perlmain.c, modified to run perl with the arguments
passed. I<LIST> should B<not> include C<argv[0]>, as that will passed
from C<main> when the program is invoked. This is necessary as on many
platforms C<$^X> is calculated from e.g. F</proc/self/exe>, and ignores
the passed C<argv[0]>.

Any additional arguments passed to the resulting executable will be
added to C<perl_parse>'s C<argv>, after a C<-->.

=cut

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

=end internals

=head2 build_exe I<OPTIONS>

Compiles and links a version of perl that runs with the supplied
arguments. I<OPTIONS> should be a set of key/value pairs. Valid options
are

=over 4

=item perl

An arrayref of options to pass to perl. Do not include the script or any
arguments for C<@ARGV> here; see the C<script> and C<argv> options.

=item script

The script file to convert. If this is an arrayref, the array will be
passed to L<Path::Class|Path::Class>.

=item type

The type of executable to create. Currently there are three types:

=over 4

=item noscript

Don't include a script at all, just compile-in the command line options
given.

=item path

Compile in the path given, so that the generated executable will always
run that file. You probably want to make this an absolute path, as the
function will just compile-in whatever string you specify.

=item append

Append the script to the executable file, and read it from there at
runtime. The generated executable will require the
L<PerlIO::subfile|PerlIO::subfile> module at runtime.

=back

=item argv

An arrayref of arguments to go in @ARGV. Any arguments passed on the
command-line will be appended to these.

=item output

Where to put the generated exe. Defaults to F<a.out>, like all good
compilers.

=item verbose

A number from 0 to 3. Numbers greater than 0 will produce output as the
build progresses. This will be emitted with C<warn>, so it can be caught
using C<$SIG{__WARN__}> if necessary.

=back

=cut

my %Srcs = (
    ""                      => [qw/exemain pl2exe/],
    NEED_FAKE_WIN32CORE     => ["Win32CORE"],
);

# arguments must be Path::Class objects

sub cp {
    my ($from, $to) = @_;
   
    -d $to and $to = $to->file($from->basename);
    _msg 2, qq/cp "$from" "$to"/;
    # File::Copy doesn't stringify properly
    File::Copy::cp "$from", "$to";
}

sub build_exe {
    my %opts = @_;

    $opts{type} ||= $opts{script} ? "append" : "noscript";
    $opts{perl} =   [@{$opts{perl} || []}];
    $opts{argv} =   [@{$opts{argv} || []}];

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
        when ("noscript") {
            push @{$opts{perl}}, "--";
        }
    }

    _msg 1, "Generating source...";

    # File::Slurp doesn't stringify objects properly
    write_file "".$tmp->file("exemain.c"), exemain;
    write_file "".$tmp->file("subst.h"),   subst_h
        type    => $opts{type},
        offset  => $offset,
        argv    => [@{$opts{perl}}, @{$opts{argv}}];

    my @srcs = map {
        (not length or $P2EConfig{$_})
            ? @{$Srcs{$_}} : ()
    } keys %Srcs;

    my $dist = dir dist_dir $DIST;
    cp $_, $tmp
        for (grep -f, map $dist->file("$_.c"), @srcs),
            (grep /\.h$/, $dist->children);

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

C<$^X> will be set to the perl that was used to generate the executable.
If that perl is moved or removed, C<$^X> will no longer be valid in the
executed program.

B<Do not> attempt to pass C<-P> to perl. C<-P> cannot work anyway, and
the executable will croak when it is run, but before it does it will
execute a copy of itself as part of the C<-P> processing. The only way
to stop the loop is to rename the executable.

C<< type => "append" >> is incompatible with taint mode, as there is no way
to securely open a filehandle on the current executable. If an exe built
with C<< type => "append" >> finds it has started in taint mode, it will
exit with the message "Insecure dependency in appended script".

Please report bugs to <bug-ExtUtils-PerlToExe@rt.cpan.org>.

=head1 AUTHOR

Ben Morrow <ben@morrow.me.uk>

=head1 COPYRIGHT

Copyright 2009 Ben Morrow.

This program may be distributed under the same terms as perl itself.

