#!/usr/bin/perl

use warnings;
use strict;

use Test::More;

use ExtUtils::PerlToExe     qw/build_exe/;
use Config;
use IPC::Run                qw/run/;
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

sub exe_is {
    my ($opts, $expout, $experr, $name) = @_;
    my $B = Test::More->builder;

    ref $opts eq "ARRAY" and
        $opts = { perl => $opts };

    $opts->{output} ||= "a$_exe";
    my $exe = file curdir, $opts->{output};

    ref $opts->{script} eq "ARRAY" and
        $opts->{script} = file @{$opts->{script}};

    my $rv = eval { build_exe %$opts };
    my $E = $@;

    if ($B->ok($rv, "$name builds OK")) {
        $rv = run [$exe], \"", \my ($gotout, $goterr);
        $B->ok($rv, "...runs OK");
        $B->is_or_like($gotout, $expout, "...correct STDOUT");
        $B->is_or_like($goterr, $experr, "...correct STDERR");
    }
    else {
        $B->diag($E);
        $B->skip("(exe did not build)") for 1..3;
    }

    unlink $exe;
}

BEGIN { $t += 4 * 4 }

exe_is ["-e1"], "", "",                     "-e1";
exe_is ["-MExporter", "-e1"], "", "",       "nonXS module";
exe_is ["-MFile::Glob", "-e1"], "", "",     "XS module";

exe_is { perl => ["-e1"], output => "foo$_exe" },
    "", "",                                 "with -o";

BEGIN { $t += 3 * 4 }

my $layers  = join "", map "$_\n", PerlIO::get_layers(\*DATA);
my $subfile = qr/\A\Q$layers\Esubfile\(.*\)\n\z/;

exe_is {
    script  => [qw/t layers/],
    type    => "append",
}, $subfile, "",                            "-T append uses :subfile";

exe_is {
    script  => [qw/t layers/],
    type    => "path",
}, $layers, "",                             "-T path doesn't";

exe_is {
    script  => [qw/t layers/],
}, $subfile, "",                            "default is -T append";

BEGIN { $t += 3 * 4 }

exe_is ["-eprint \$^X"], $^X, "",           "\$^X with -T noscript";
exe_is { 
    script => [qw/t ctrlX/],
}, $^X, "",                                 "\$^X with -T append";
exe_is { 
    script => [qw/t ctrlX/],
    type => "path",
}, $^X, "",                                 "$^X with -T path";

BEGIN { plan tests => $t }

__DATA__
