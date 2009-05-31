/* Copyright 2009 Ben Morrow <ben@morrow.me.uk> */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "pl2exe.h"
#include "subst.h"

static void my_xsinit(pTHX);
static XSINIT_t     real_xsinit;

#ifdef ARGC
static char         argv_buf[ARGV_BUF_LEN] = ARGV_BUF;
#endif

#if defined(OFFSET) || defined(USE_ZIP)
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
#ifdef ARGC
    int i;
    char *my_argv[ARGC + argc];

    my_argv[0] = argv[0];
    INIT_MY_ARGV;

    /* argv has an extra "\\0" on the end, so we can go all 
       the way up to argv[argc] */

    for (i = 0; i < argc; i++) {
        my_argv[i + ARGC] = argv[i + 1];
    }

    i += ARGC - 1;
#else
# define my_argv argv
# define i argc
#endif

    real_xsinit = xsinit;

    return perl_parse(interp, my_xsinit, i, my_argv, env);

#undef my_argv
#undef i
}

void
my_xsinit(pTHX)
{
    dVAR;
    static const char file[] = __FILE__;
    GV *ctlXgv;
    SV *ctlX;

    ctlXgv = gv_fetchpvs("\030", GV_NOTQUAL, SVt_PV);
    ctlX   = GvSV(ctlXgv);

#ifdef NEED_INIT_WIN32CORE
    init_Win32CORE(aTHX);
#endif

#ifdef USE_ZIP
    pl2exe_boot_zip(aTHX);
#endif

#if defined(OFFSET) || defined(USE_ZIP)

    newXS("ExtUtils::PerlToExe::fakescript",
        XS_ExtUtils_PerlToExe_fakescript,
        file);

    if (!PL_preambleav)
        PL_preambleav = newAV();
    av_push(PL_preambleav, 
        newSVpvs("BEGIN { ExtUtils::PerlToExe::fakescript() }"));

    TAINT;
#ifdef USE_ZIP
    TAINT_PROPER("appended zipfile");
#else
    TAINT_PROPER("appended script");
#endif
    TAINT_NOT;

#ifdef OFFSET
    if (PL_preprocess)
        croak("Can't use -P with pl2exe");
#endif

    /*
     * We can't reopen PL_rsfp yet as it hasn't been set (the file is
     * open, it's just in an auto variable in S_parse_body). However,
     * it's easier to fixup the name here, before gv_fetch_file gets
     * called on it.
     */

    PL_origfilename = savepv(SvPV_nolen(ctlX));
    CopFILE_free(PL_curcop);
    CopFILE_set(PL_curcop, PL_origfilename);

#endif /* OFFSET || USE_ZIP */

#ifdef USE_ZIP
    pl2exe_load_zip(aTHX_ PL_origfilename);
#endif

#ifdef CTL_X
    sv_setpv(ctlX, CTL_X);
    SvTAINTED_on(ctlX);
#endif

    real_xsinit(aTHX);
}

#if defined(OFFSET) || defined(USE_ZIP)

#define PL_rsfp (PL_parser->rsfp)

XS(XS_ExtUtils_PerlToExe_fakescript)
{
    dVAR;
    dXSARGS;

#ifdef OFFSET
    Perl_load_module(aTHX_ 0, newSVpvs("PerlIO::subfile"), NULL, NULL);

    PerlIO_close(PL_rsfp);
    PL_rsfp = PerlIO_open(PL_origfilename, "r");
    PerlIO_seek(PL_rsfp, -OFFSET, SEEK_END);

    PerlIO_apply_layers(aTHX_ PL_rsfp, "r", ":subfile");
#endif

}

#endif /* OFFSET || USE_ZIP */
