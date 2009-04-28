/* Copyright 2009 Ben Morrow <ben@morrow.me.uk> */

/* 
 * This file has substitutions made in it by ExtUtils::PerlToExe, using
 * Template::Simple. c.f. for the syntax.
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "pl2exe.h"

static void my_xsinit(pTHX);

static char         argv_buf[$(buf_len)] = $(argv_buf);
static XSINIT_t     real_xsinit;

/*
 * This is our main hook into perl startup. We rewrite argv, then call
 * the real perl_parse with a new xsinit. This in turn installs perl
 * code into PL_preambleav, then calls the real xs_init.
 */

int
pl2exe_perl_parse(
    PerlInterpreter *interp,
    XSINIT_t         xsinit,
    int argc, char **argv, char **env
)
{
    int i;
    char *my_argv[$(argc) + argc];

    real_xsinit = xsinit;

    my_argv[0] = argv[0];
  
    $(start my_argv_init)
    my_argv[$(n)] = argv_buf + $(ptr);
    $(end my_argv_init)

    /* argv has an extra "\\0" on the end, so we can go all 
       the way up to argv[argc] */

    for (i = 0; i < argc; i++) {
        my_argv[i + $(argc)] = argv[i + 1];
    }

    i += $(argc) - 1;

    return perl_parse(interp, my_xsinit, i, my_argv, env);
}

void
my_xsinit(pTHX)
{
    Perl_av_create_and_push(aTHX_ &PL_preambleav, 
        newSVpvs("warn 'Hello world!'"));

    real_xsinit(aTHX);
}

