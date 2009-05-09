#!/usr/bin/perl

use warnings;
use strict;

use Test::More;

use ExtUtils::PerlToExe     qw/build_exe/;
use Config;
use File::Temp              qw/tempfile/;
use Fcntl                   qw/SEEK_SET/;
use File::Spec::Functions   qw/curdir/;
use Path::Class             qw/file/;

my $t;

my $_exe = $Config{_exe} || ".out";

sub Test::Builder::is_or_like {
    my ($B, $got, $exp, $name) = @_;
    ref $exp 
        ? $B->like($got, $exp, $name) 
        : $B->is_eq($got, $exp, $name);
}

sub run {
    my ($cmd, $in, $out, $err) = @_;

    my @STD = (\*STDIN, \*STDOUT, \*STDERR);
    my (@NEW, @OLD);

    for (0..2) {
        $NEW[$_] = tempfile;
        my $dir = $_ ? ">" : "<";
        open $OLD[$_], "$dir&", $STD[$_];
        open $STD[$_], "$dir&", $NEW[$_];
    }
    print {$NEW[0]} $$in;

    my $ev = system @$cmd;

    for (0..2) {
        my $dir = $_ ? ">" : "<";
        open $STD[$_], "$dir&", $OLD[$_];
    }

    seek $NEW[$_], 0, SEEK_SET for 1..2;
    local $/ = undef;
    $$out = readline $NEW[1];
    $$err = readline $NEW[2];

    return $ev & 127 ? undef : $ev >> 8;
}

sub exe_is {
    my $exit = 0;
    @_ == 5 and ($exit) = splice @_, 3, 1;
    my ($opts, $expout, $experr, $name) = @_;
    my $B = Test::More->builder;

    ref $opts eq "ARRAY" and
        $opts = { perl => $opts };

    $opts->{output} ||= "a$_exe";
    my $exe = file($opts->{output})->absolute;

    ref $opts->{script} eq "ARRAY" and
        $opts->{script} = file @{$opts->{script}};

    my $rv = eval { build_exe %$opts };
    my $E = $@;

    if ($B->ok($rv, "$name builds OK")) {
        $rv = run [$exe], \"", \my ($gotout, $goterr);
        $B->ok(defined $rv, "...runs OK");
        $B->is_num($rv, $exit, "...correct exit code");
        $B->is_or_like($gotout, $expout, "...correct STDOUT");
        $B->is_or_like($goterr, $experr, "...correct STDERR");
    }
    else {
        $B->diag($E);
        $B->skip("(exe did not build)") for 1..3;
    }

    unlink $exe;
}

BEGIN { $t += 4 * 5 }

exe_is ["-e1"], "", "",                     "-e1";
exe_is ["-MExporter", "-e1"], "", "",       "nonXS module";
exe_is ["-MFile::Glob", "-e1"], "", "",     "XS module";

exe_is { perl => ["-e1"], output => "foo$_exe" },
    "", "",                                 "with -o";

BEGIN { $t += 3 * 5 }

my $layers  = join "", map "$_\n", PerlIO::get_layers(\*DATA);
my $subfile = qr/\A\Q$layers\Esubfile\(.*\)\n\z/;

exe_is {
    script  => [qw/t layers/],
    type    => "append",
}, $subfile, "",                    "-T append uses :subfile";

exe_is {
    script  => [qw/t layers/],
    type    => "path",
}, $layers, "",                     "-T path doesn't";

exe_is {
    script  => [qw/t layers/],
}, $subfile, "",                    "default is -T append";

BEGIN { $t += 3 * 5 }

exe_is ["-eprint \$^X"], $^X, "",   "\$^X with -T noscript";

exe_is { 
    script => [qw/t ctrlX/],
}, $^X, "",                         "\$^X with -T append";

exe_is { 
    script => [qw/t ctrlX/],
    type => "path",
}, $^X, "",                         "\$^X with -T path";

BEGIN { $t += 3 * 5 }

my $taint = "Insecure dependency in";

exe_is ["-T", "-e1"], "", "",        "taint with -T noscript";

exe_is {
    perl   => ["-T"],
    script => [qw/t null/],
}, "", qr/$taint appended script/, 255,
                                    "taint with -T append";

exe_is {
    perl    => ["-T"],
    script  => [qw/t null/],
    type    => "path",
}, "", "",                          "taint with -T path";

BEGIN { $t += 2 * 5 }

exe_is ["-Teopen X, '>>', \$^X"],
    "", qr/$taint open/, 255,       "\$^X is tainted with -T noscript";

exe_is {
    perl    => ["-T"],
    script  => [qw/t ctrlX/],
    type    => "path",
}, "", qr/$taint open/, 255,        "\$^X is tainted with -T path";

BEGIN { plan tests => $t }

__DATA__
