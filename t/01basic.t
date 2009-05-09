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

sub has_XS {
    my ($C, $mod, $name) = @_;
    my $B = Test::More->builder;

    my $strap = $mod eq "DynaLoader" ? "_DynaLoader" : "strap";
    (my $boot  = "boot_$mod") =~ s/:/_/g;
    my $rx = qr/\QnewXS("${mod}::boot$strap", $boot, file)/;

    $B->like($C, $rx, $name);
}

{
    BEGIN { $t += 4 }

    no warnings "redefine";
    local *ExtUtils::Embed::static_ext = sub { qw/DynaLoader Foo::Bar/ };

    for my $try ("", " (second time)") {
        my $C = perlmain;

        has_XS $C, "DynaLoader", "perlmain provides boot_DynaLoader$try";
        has_XS $C, "Foo::Bar",   "perlmain provies boot_Foo__Bar$try";
    }
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

{
    BEGIN { $t += 6 }

    my @warn;
    local $SIG{__WARN__} = sub { push @warn, $_[0] };

    ExtUtils::PerlToExe::_msg 1, "foo";
    is  @warn,      0,              "msg doesn't warn without -v";

    local $ExtUtils::PerlToExe::Verb = 2;

    @warn = ();
    ExtUtils::PerlToExe::_msg 1, "foo";

    is  @warn,      1,              "msg warns for high -v";
    is  $warn[0],   "foo\n",        "...correctly";

    @warn = ();
    ExtUtils::PerlToExe::_msg 2, "bar";

    is  @warn,      1,              "msg warns for exact -v";
    is  $warn[0],   "bar\n",        "...correctly";

    @warn = ();
    ExtUtils::PerlToExe::_msg 3, "baz";

    is  @warn,      0,              "msg doesn't warn for low -v";
}

BEGIN { plan tests => $t }
