#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use t::BuildExe;
use Config;

use Archive::Zip    qw/:ERROR_CODES/;

my $_exe = ($Config{_exe} || ".out");

my $t;

BEGIN { $t += 7 }

my $exe = "zip$_exe";

build_ok {
    output  => $exe,
    perl    => ["-e1"],
    type    => "zip",
    zip     => "t",
},                                          "included zipfile";

ok -x $exe,                                 "...is executable";
ok +Archive::Zip->new($exe),                "...is a zipfile";

run_is $exe, ["", ""],                      "included zipfile";

unlink $exe;

BEGIN { $t += 3 }

build_ok {
    output  => $exe,
    perl    => ["-e1"],
    zip     => "t",
},                                          "-Z implies -T zip";

ok -x $exe,                                 "...is executable";
ok +Archive::Zip->new($exe),                "...is a zipfile";

unlink $exe;

BEGIN { plan tests => $t }
