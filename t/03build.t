#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use t::BuildExe;

use Config;
use Path::Class     qw/file/;

my $_exe = ($Config{_exe} || ".out");

my $t;

BEGIN { $t += 6 + 2 * 5 }

build_ok { perl => ["-e1"] },               "-e1 builds OK";
ok -x "a$_exe",                             "...and is executable";
run_is "a$_exe", ["", ""],                  "-e1";

unlink "a$_exe";

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
