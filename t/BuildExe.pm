package t::BuildExe;

use ExtUtils::PerlToExe     qw/build_exe/;
use Config;
use File::Temp              qw/tempfile/;
use Fcntl                   qw/SEEK_SET/;
use File::Spec::Functions   qw/curdir/;
use Path::Class             qw/file/;

use Exporter::NoWork        qw/exe_is/;

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

