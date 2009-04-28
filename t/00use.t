#!/usr/bin/perl

use Test::More tests => 1;

use_ok "ExtUtils::PerlToExe";

BAIL_OUT "module will not load"
    if grep !$_, Test::More->builder->summary;

