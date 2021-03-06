#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use t::BuildExe;
use Config;

use Archive::Zip    qw/:ERROR_CODES/;
use Path::Class     qw/file dir/;
use File::Slurp     qw/read_file/;

my $_exe = ($Config{_exe} || ".out");

my $t;

BEGIN { $t += 7 }

# A::Z doesn't like P::C objects
my $exe = "" . file("zip$_exe")->absolute;

build_ok {
    output  => $exe,
    perl    => ["-e1"],
    type    => "zip",
    zip     => "t",
},                                  "included zipfile";

ok -x $exe,                         "...is executable";
ok +Archive::Zip->new($exe),        "...is a zipfile";

run_is $exe, ["", ""],              "included zipfile";

unlink $exe;

BAIL_OUT "can't include a zipfile"
    if grep !$_, Test::More->builder->summary;

BEGIN { $t += 3 }

build_ok {
    output  => $exe,
    perl    => ["-e1"],
    zip     => "t",
},                                  "-Z implies -T zip";

ok -x $exe,                         "...is executable";
ok +Archive::Zip->new($exe),        "...is a zipfile";

unlink $exe;

BEGIN { $t += 2 * 5 }

exe_is {
    perl    => ["-eprint \$INC[0]->isa('ExtUtils::PerlToExe::INC')"],
    zip     => "t",
}, ["1", ""],                       "-Tzip adds E:P:INC to \@INC";

exe_is {
    output  => $exe,
    perl    => ["-eprint \$INC[0]->name"],
    zip     => "t",
}, [$exe, ""],                      "...with correct zipfile";

BEGIN { $t += 2 * 5 }

exe_is {
    perl    => ["-MScalar::Util=openhandle", <<'PERL'],
-eprint !!openhandle($INC[0]->INC("04zip.t"))
PERL
    zip     => "t",
}, ["1", ""],                       "EPI->INC returns a FH";

exe_is {
    perl    => [<<'PERL'],
-eprint $INC[0]->INC("04zip.t")
    ->isa("ExtUtils::PerlToExe::INC")
PERL
    zip     => "t",
}, ["1", ""],                       "...in the correct class";

BEGIN { $t += 2 * 5 }

for (qw/crlf nocrlf/) {
    my $file = read_file "".dir("t")->file($_), binmode => 1;

    exe_is {
        perl    => [<<PERL],
-elocal \$/; 
binmode STDOUT;
print readline \$INC[0]->INC("$_");
PERL
        zip     => "t",
    }, [$file, ""],                 "...with the correct contents ($_)";
}

BEGIN { $t += 5 }

exe_is {
    perl    => ["-MDummy", "-eprint \$Dummy::Dummy"],
    zip     => "t",
}, [42, ""],                        "\@INC hook works";

BEGIN { plan tests => $t }
