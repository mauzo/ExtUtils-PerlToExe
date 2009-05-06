#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use ExtUtils::PerlToExe qw/:ALL/;
use IPC::Run            qw/run/;
use Config;

my $t;

{
    BEGIN { $t += 2 }

    open my $OLDOUT, ">&", \*STDOUT;
    open STDOUT, ">", \(my $out = "");

    my $C = perlmain;

    open STDOUT, ">&", $OLDOUT;

    like    $C,     qr/perl_parse/,     "perlmain returns perlmain.c";
    is      $out,   "",                 "...without writing to STDOUT";
}

{
    my %strings;
    BEGIN {
        %strings = (
            qq/foo/,                qq/"foo"/,
            qq/\nnewline/,          qq/"\\n"\n"newline"/,
            qq/\0null/,             qq/"\\0"\n"null"/,
            qq/\\backslash/,        qq/"\\\\backslash"/,
            qq/\\not newline/,      qq/"\\\\not newline"/,
            qq/\ttab/,              qq/"\\011tab"/,
            qq/ \x{ff}binary/,      qq/" \\377binary"/,
            "long " . ("a" x 75),   <<C,
"long aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
"aaaaaaaaaa"
C
            "aa\nbb\0c \t",         <<C,
"aa\\n"
"bb\\0"
"c \\011"
C
            "two long lines\n" . ("a" x 75) . "\n" . ("b" x 75),     
                                    <<C,
"two long lines\\n"
"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
"aaaaa\\n"
"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
"bbbbb"
C
        );

        $t += 2 * keys %strings;
    }

    for (keys %strings) {
        chomp $strings{$_};
        (my $name = substr $_, 0, 14) =~ s/[^a-zA-Z]/?/g;
        is str_to_C($_),    $strings{$_}, "str_to_C $name";
        is str_to_C,        $strings{$_}, "...implicit \$_";
    }
}

{
    BEGIN { $t += 2 }

    my $M = exemain;

    like   $M,  qr/\n#include "pl2exe.h"\n/, "exemain #includes pl2exe.h";
    unlike $M,  qr/\n[ \t]+#/,               "cpp at left margin";
}

BEGIN { $t += 2 }

is define(FOO => 1),            <<C,    "basic #defines";
#define FOO 1
C

is define(FOO => "one\ntwo"),   <<C,    "#defines with newlines";
#define FOO one\\
two
C

my $aout = "a" . ($Config{_exe} || ".out");

sub exe_is {
    my ($args, $expout, $experr, $name) = @_;
    my $B = Test::More->builder;

    my $rv = eval { build_exe $aout, @$args };

    if ($B->ok($rv, "$name builds OK")) {
        $rv = run ["./$aout"], \"", \my ($gotout, $goterr);
        $B->ok($rv, "...runs OK");
        $B->is_eq($gotout, $expout, "...correct STDOUT");
        $B->is_eq($goterr, $experr, "...correct STDERR");
    }
    else {
        $B->skip("(exe did not build)") for 1..3;
    }

    unlink $aout;
}

{
    BEGIN { $t += 3 * 4 }

    exe_is ["-e1"], "", "",                     "-e1";
    exe_is ["-MExporter", "-e1"], "", "",       "nonXS module";
    exe_is ["-MFile::Glob", "-e1"], "", "",     "XS module";
}

BEGIN { plan tests => $t }
