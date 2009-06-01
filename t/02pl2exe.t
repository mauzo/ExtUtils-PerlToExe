#!/usr/bin/perl

use warnings;
use strict;

use Test::More;

use ExtUtils::PerlToExe ();
use Path::Class;
use Data::Dump qw/dump/;

my $t;

my %opts;
{
    no warnings "redefine";
    *ExtUtils::PerlToExe::build_exe = sub { %opts = @_ };
}

my $pl2exe = file qw/blib script pl2exe/;

sub p2e_is {
    my ($argv, $exp, $name) = @_;

    local @ARGV = @$argv;
    do $pl2exe;

    # annoyingly, Test::Builder doesn't provide is_deeply
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is_deeply \%opts, $exp, $name;
}

{
    BEGIN { $t += 10 }

    p2e_is [qw/foo/], 
        { script => "foo", perl => [] },
        "basic perl2exe invocation";

    p2e_is [qw/-o bar foo/],
        { script => "foo", perl => [], output => "bar" },
        "pass -o to pl2exe";

    p2e_is [qw/-v foo/],
        { script => "foo", perl => [], verbose => 1 },
        "pass -v to pl2exe";

    p2e_is [qw/foo -v/],
        { script => "foo", perl => ["-v"] },
        "pass -v to perl";

    p2e_is [qw/-- -v/],
        { perl => ["-v"] },
        "just pass -v to perl";

    p2e_is [qw/-- -- -v/],
        { perl => [], argv => ["-v"] },
        "pass -v to argv";

    p2e_is [qw/-T path foo/],
        { script => "foo", type => "path", perl => [] },
        "-T takes an argument";

    p2e_is [qw/-Tpath foo/],
        { script => "foo", type => "path", perl => [] },
        "...which can be bundled";

    p2e_is [qw/-Z dir foo/],
        { script => "foo", zip => "dir", perl => [] },
        "-Z takes an argument";

    p2e_is [qw/-Z dir -- -e1/],
        { zip => "dir", perl => ["-e1"] },
        "-Z can be used with no script";
}


BEGIN { plan tests => $t }
