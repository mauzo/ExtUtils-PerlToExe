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

use Fcntl               qw/:seek/;

use Cwd                 qw/cwd/;
use Path::Class         qw/dir file/;
use File::Spec::Functions   qw/devnull curdir/;
use File::Temp          qw/tempdir/;
use File::Copy          qw/cp/;
use File::Slurp         qw/read_file write_file read_dir/;
use File::ShareDir      qw/dist_dir dist_file/;

use List::Util          qw/max/;
use Data::Alias;
use Data::Dump qw/dump/;

use IPC::System::Simple qw/system/;
use Archive::Zip        qw/:ERROR_CODES/;

my $DIST = "ExtUtils-PerlToExe";

our %P2EConfig;
# require always takes /-separated paths
require "ExtUtils/PerlToExe/config.pl";

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
    my @ext = @_;

    open my $MAIN, ">", \(my $C = "");
    my $OLD = select $MAIN;

    # Ugh. At least it's a global...
    local %ExtUtils::Miniperl::SEEN;
    @ext = 
        grep !m!XS/APItest|XS/Typemap!,
        ExtUtils::Embed::static_ext,
        @ext;
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
    my $C = perlmain @_;
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

    my %H = (
        USE_MY_ARGV     => 1,
        ARGC            => @argv + 1,
        ARGV_BUF        => str_to_C(join "", map "$_\0", @argv),
        INIT_MY_ARGV    => 
            "STMT_START {\n" . 
            join("\n", map {
                my $optr = $ptr;
                $ptr += 1 + length $argv[$_ - 1];
                "my_argv[$_] = argv_buf + $optr;";
            } 1..@argv) .
            "\n} STMT_END",

        USE_CTRLX       => 1,
        CTRL_X          => str_to_C($^X),
    );

    given ($opts{type}) {
        when ("append") {
            %H = (%H,
                USE_SUBFILE => 1,
                OFFSET      => $opts{offset},
            );
        }
        when ("zip") {
            $H{USE_ZIP} = 1;
            $opts{script} and $H{USE_ZIP_SCRIPT} = 1;
        }
    }

    return %H;
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
    USE_ZIP                 => ["zip"],
);

my %Ext = (
    USE_SUBFILE     => ["PerlIO::subfile"],
    USE_ZIP         => ["PerlIO::gzip"],
);

# arguments must be Path::Class objects

sub _cp {
    my ($from, $to) = @_;
   
    -d $to and $to = $to->file($from->basename);
    _msg 2, qq/cp "$from" "$to"/;
    # File::Copy doesn't stringify properly
    File::Copy::cp "$from", "$to";
}

sub build_exe {
    my %opts = @_;

    unless ($opts{type}) {
        $opts{type} = "noscript";
        $opts{script}   and $opts{type} = "append";
        $opts{zip}      and $opts{type} = "zip";
    }
    $opts{perl} =   [@{$opts{perl} || []}];
    $opts{argv} =   [@{$opts{argv} || []}];

    $opts{ext} ||= [];

    ref $opts{script} eq "ARRAY"
        and $opts{script} = file @{$opts{script}};

    my $exe = $opts{output} // "a" . $P2EConfig{_exe};
    $exe = file($exe)->absolute;

    $Verb = $ENV{PL2EXE_VERBOSE} || $opts{verbose} || 0;

    _msg 3, "Building an exe with " . dump \%opts;

    my $tmp = dir tempdir CLEANUP => !$ENV{PL2EXE_NO_CLEANUP};
    _msg 3, "Using tempdir $tmp";

    my $ccopts = $P2EConfig{ccopts};
    my $ldopts = $P2EConfig{ldopts};

    my ($SCRP, $offset, $zip);

    given ($opts{type}) {
        when ("zip") {
            $zip = Archive::Zip->new;
            $zip->addTree($opts{zip}, "");

            if ($opts{script}) {
                my $m;
                $m = $zip->addFile($opts{script}, "script.pl")
                    and $m->isBinaryFile(1);
                push @{$opts{perl}}, devnull;
            }
        }
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

    my $oldcwd = cwd;
    chdir $tmp;

    my %subst = subst_h
        type    => $opts{type},
        offset  => $offset,
        argv    => [@{$opts{perl}}, @{$opts{argv}}],
        script  => $opts{script};

    my $subst = define %subst;

    my @srcs = (
        @{$P2EConfig{srcs}},
        map @{$Srcs{$_}},
            grep $subst{$_},
            keys %Srcs,
    );

    my @ext = (
        @{$opts{ext}},
        map @{$Ext{$_}},
            grep $subst{$_},
            keys %Ext,
    );

    _msg 3, "Writing exemain.c with @ext.";
    write_file "exemain.c",     exemain @ext;
    _msg 3, "Writing subst.h with", $subst;
    write_file "subst.h",       $subst;
    write_file "p2econfig.h",   define %{$P2EConfig{define}};

    my $dist = dir dist_dir $DIST;
    _cp $_, $tmp
        for (grep -f, map $dist->file("$_.c"), @srcs),
            (grep /\.h$/, $dist->children);

    my @objs;
    
    _msg 1, "Compiling...";
    for (@srcs) {
        my $c = "$_.c";
        my $o = "$_$Config{_o}";
        push @objs, $o;
        _mysystem qq!$Config{cc} -c $ccopts -o $o $c!
    }

    _msg 1, "Linking...";

    my (@libs, @extrald);
    EXT: for my $ext (@ext) {
        _msg 3, "looking for $ext...";
        my @ns    = split /::/, $ext;

        DIR: for my $inc (@INC) {

            my $dir = dir $inc, "auto", @ns;
            my $lib = $dir->file("$ns[-1]$Config{_a}");
            _msg 3, "trying $lib...";

            -e $lib or next DIR;
            push @libs, $lib;
            _msg 3, "OK.";

            my $extra = $dir->file("extralibs.ld");
            -e $extra or next EXT;

            my @extra = grep length, split /\s+/, read_file "".$extra;
            push @extrald, @extra;
            @extra and _msg 3, "got @extra from $extra.";

            next EXT;
        }
    }

    _mysystem 
        qq!$Config{ld} $P2EConfig{ldout}"$exe" @objs @libs $ldopts @extrald!;

    chdir $oldcwd;

    open my $OUT, "+<:raw", $exe
        or die "can't append to '$exe': $!\n";
    seek $OUT, 0, SEEK_END
        or die "can't append to '$exe': $!\n";

    given ($opts{type}) {
        when ("append") {
            _msg 1, "Appending script...";
            _msg 2, qq/cat "$opts{script}" >> "$exe"/;

            cp $SCRP, $OUT;
        }
        when ("zip") {
            _msg 1, "Appending zipfile...";
            _msg 2, qq/zip -r - "$opts{zip}" >> "$exe"/;

            for ($zip->members) {
                _msg 3, sprintf "path: %s, file: %s",
                    $_->fileName, $_->externalFileName;
            }

            $zip->writeToFileHandle($OUT, 1) == AZ_OK
                or die "writing zipfile failedi\n";
        }
    }

    close $OUT;
    chmod 0755, $exe;

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

