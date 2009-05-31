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

sub dotodo {
    my ($why) = @_;
    my $B = Test::More->builder;
    $B->in_todo and $B->todo_end;
    $why and $B->todo_start($why);
}

sub exe_is {
    my $exit = 0;
    @_ == 5 and ($exit) = splice @_, 3, 1;
    my ($p2e, $opts, $name) = @_;
    my $B = Test::More->builder;

    ref $p2e eq "ARRAY" and
        $p2e = { perl => $p2e };
    $p2e->{output} ||= "a$_exe";
    my $exe = file($p2e->{output})->absolute;

    if (ref $opts eq "ARRAY") {
        my $tmp = $opts;
        $opts = {
            stdout => $tmp->[0],
            stderr => $tmp->[1],
        };
        @$tmp > 2 and $opts->{exit} = $tmp->[2];
    }

    $opts->{argv} ||= [];
    exists $opts->{exit} or $opts->{exit} = 0;
    $_ //= "" for @{$opts}{qw/stdin stdout stderr/};

    my $rv = eval { build_exe %$p2e };
    my $E = $@;

    dotodo $opts->{todo}{build};;
    if ($B->ok($rv, "$name builds OK")) {

        dotodo $opts->{todo}{run};
        $rv = run 
            [$exe, @{$opts->{argv}}], 
            \($opts->{stdin}), \my ($gotout, $goterr);
        $B->ok(defined $rv, "...runs OK");

        dotodo $opts->{todo}{exit};
        $B->is_num($rv, $opts->{exit}, "...correct exit code");
        dotodo $opts->{todo}{stdout};
        $B->is_or_like($gotout, $opts->{stdout}, "...correct STDOUT");
        dotodo $opts->{todo}{stderr};
        $B->is_or_like($goterr, $opts->{stderr}, "...correct STDERR");
    }
    else {
        $B->diag($E);
        $B->skip("(exe did not build)") for 1..3;
    }
    dotodo;

    unlink $exe;
}

BEGIN { $t += 3 * 5 }

exe_is ["-e1"], ["", ""],                   "-e1";
exe_is ["-MExporter", "-e1"], ["", ""],     "nonXS module";
exe_is ["-MFile::Glob", "-e1"], ["", ""],   "XS module";

BAIL_OUT "basic exe building fails"
    if grep !$_, Test::More->builder->summary;

BEGIN { $t += 5 }

SKIP: {
    defined &Win32::DomainName or skip "No Win32::*", 5;
    exe_is ["-eWin32::DomainName()"], ["", ""], "Win32CORE";
}

BEGIN { $t += 5 * 5 }

exe_is { perl => ["-e1"], output => "foo$_exe" },
    ["", ""],                               "with -o";

exe_is { script => file("t", "null") },
    ["", ""],                               "empty script";
exe_is { script => ["t", "null"] },
    ["", ""],                               "script uses Path::Class";
exe_is {
    script  => ["t", "null"],
    type    => "append",
}, ["", ""],                                "empty script -T append";
exe_is {
    script  => ["t", "null"],
    type    => "path",
}, ["", ""],                                "empty script -T path";

BEGIN { $t += 3 * 5 }

my $layers  = join "", map "$_\n", PerlIO::get_layers(\*DATA);
my $subfile = qr/\A\Q$layers\Esubfile\(.*\)\n\z/;

exe_is {
    script  => [qw/t layers/],
    type    => "append",
}, [$subfile, ""],                  "-T append uses :subfile";

exe_is {
    script  => [qw/t layers/],
    type    => "path",
}, [$layers, ""],                   "-T path doesn't";

exe_is {
    script  => [qw/t layers/],
}, [$subfile, ""],                  "default is -T append";

BEGIN { $t += 3 * 5 }

exe_is ["-eprint \$^X"], [$^X, ""], "\$^X with -T noscript";

exe_is { 
    script => [qw/t ctrlX/],
}, [$^X, ""],                       "\$^X with -T append";

exe_is { 
    script => [qw/t ctrlX/],
    type => "path",
}, [$^X, ""],                       "\$^X with -T path";

BEGIN { $t += 3 * 5 }

my $taint = "Insecure dependency in";

exe_is ["-T", "-e1"], ["", ""],     "taint with -T noscript";

exe_is {
    perl    => ["-T"],
    script  => [qw/t null/],
}, {
    stdout  => "", 
    stderr  => qr/$taint appended script/, 
    exit    => 255,
    todo    => { exit => "exit status wrong: don't know why yet" },
},                                  "taint with -T append";

exe_is {
    perl    => ["-T"],
    script  => [qw/t null/],
    type    => "path",
}, ["", ""],                        "taint with -T path";

BEGIN { $t += 2 * 5 }

exe_is ["-Teopen X, '>>', \$^X"],
    ["", qr/$taint open/, 255],     "\$^X is tainted with -T noscript";

exe_is {
    perl    => ["-T"],
    script  => [qw/t ctrlX/],
    type    => "path",
}, ["", qr/$taint open/, 255],      "\$^X is tainted with -T path";

BEGIN { $t += 4 * 5 }

my $e_argv = [
    '-e$\ = "\n";',
    '-ebinmode STDOUT;',
    '-eprint for @ARGV;',
];

exe_is $e_argv, ["", ""],           "empty ARGV";

exe_is {
    perl => $e_argv,
    argv => [qw/one two/],
}, [<<OUT, ""],                     "compiled-in ARGV";
one
two
OUT

exe_is $e_argv, {
    argv    => [qw/one two/],
    stdout  => <<OUT,
one
two
OUT
},                                  "supplied ARGV";

exe_is {
    perl    => $e_argv,
    argv    => [qw/one two/],
}, {
    argv    => [qw/three four/],
    stdout  => <<OUT,
one
two
three
four
OUT
},                                  "built-in and supplied ARGV";

BEGIN { $t += 1 * 5 }

exe_is {
    perl    => ["-e1"],
}, {
    argv    => ["-e;print qq/foo/;"],
    stdout  => "",
},                                  "can't add -e args from argv";

BEGIN { plan tests => $t }

__DATA__
