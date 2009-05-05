/* Copyright 2009 Ben Morrow <ben@morrow.me.uk> */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "pl2exe.h"
#include "subst.h"

static void my_xsinit(pTHX);

static char         argv_buf[ARGV_BUF_LEN] = ARGV_BUF;
static XSINIT_t     real_xsinit;

#ifdef OFFSET
XS(XS_ExtUtils_PerlToExe_fakescript);
#endif

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
    char *my_argv[ARGC + argc];

    real_xsinit = xsinit;

    my_argv[0] = argv[0];
    INIT_MY_ARGV;

    /* argv has an extra "\\0" on the end, so we can go all 
       the way up to argv[argc] */

    for (i = 0; i < argc; i++) {
        my_argv[i + ARGC] = argv[i + 1];
    }

    i += ARGC - 1;

    return perl_parse(interp, my_xsinit, i, my_argv, env);
}

void
my_xsinit(pTHX)
{
#ifdef OFFSET

    dVAR;
    static const char file[] = __FILE__;
    GV *ctlXgv;

    newXS("ExtUtils::PerlToExe::fakescript",
        XS_ExtUtils_PerlToExe_fakescript,
        file);

    if (!PL_preambleav)
        PL_preambleav = newAV();
    av_push(PL_preambleav, 
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

#endif /* OFFSET */

    real_xsinit(aTHX);
}

#ifdef OFFSET

#define PL_rsfp (PL_parser->rsfp)

XS(XS_ExtUtils_PerlToExe_fakescript)
{
    dVAR;
    dXSARGS;

    Perl_load_module(aTHX_ 0, newSVpvs("PerlIO::subfile"), NULL, NULL);

    PerlIO_close(PL_rsfp);
    PL_rsfp = PerlIO_open(PL_origfilename, "r");
    PerlIO_seek(PL_rsfp, -OFFSET, SEEK_END);

    PerlIO_apply_layers(aTHX_ PL_rsfp, "r", ":subfile");
}

#endif /* OFFSET */
