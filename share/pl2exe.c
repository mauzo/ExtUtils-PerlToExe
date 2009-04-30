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

$(start if_offset)

XS(XS_ExtUtils_PerlToExe_fakescript);

$(end if_offset)

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
    $(start if_offset)

    dVAR;
    static const char file[] = __FILE__;
    GV *ctlXgv;

    newXS("ExtUtils::PerlToExe::fakescript",
        XS_ExtUtils_PerlToExe_fakescript,
        file);

    Perl_av_create_and_push(aTHX_ &PL_preambleav, 
        newSVpvs("BEGIN { ExtUtils::PerlToExe::fakescript() }"));

    /*
     * We can't reopen PL_rsfp yet as it hasn't been set (the file is
     * open, it's just in an auto variable in S_parse_body). However,
     * it's easier to fixup the name here, before gv_fetch_file gets
     * called on it.
     */

    ctlXgv = gv_fetchpvs("\030", GV_NOTQUAL, SVt_PV);

    PL_origfilename = savepv(SvPV_nolen(GvSV(ctlXgv)));
    CopFILE_free(PL_curcop);
    CopFILE_set(PL_curcop, PL_origfilename);

    $(end if_offset)

    real_xsinit(aTHX);
}

$(start if_offset)

#define PL_rsfp (PL_parser->rsfp)

XS(XS_ExtUtils_PerlToExe_fakescript)
{
    dVAR;
    dXSARGS;
    PerlIO_funcs    *layer;

    Perl_load_module(aTHX_ 0, newSVpvs("PerlIO::subfile"), NULL, NULL);

    PerlIO_close(aTHX_ PL_rsfp);
    PL_rsfp = PerlIO_open(aTHX_ PL_origfilename, "r");
    PerlIO_seek(aTHX_ PL_rsfp, -$(offset), SEEK_END);

    layer = PerlIO_find_layer(aTHX_ "subfile", 7, 0);
    PerlIO_push(aTHX_ PL_rsfp, layer, NULL, newSVuv($(offset)));
}

$(end if_offset)
