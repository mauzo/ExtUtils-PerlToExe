/* Copyright 2009 Ben Morrow <ben@morrow.me.uk> */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "pl2exe.h"
#include "subst.h"

/* 
 * FEATURE MACROS
 *
 * USE_* are defined in subst.h. They indicate features pl2exe is
 * requesting of the executable.
 *
 * NEED_* are defined in p2econfig.h, or here. They indicate features
 * that must be enabled in order to provide the USE_* features, or to
 * work around OS-specific problems.
 *
 * USE_MY_ARGV
 *  Indicates that a modified argv must be passed to perl_parse.
 *  Requires the following to also be defined:
 *      ARGV_BUF        a string constant holding the new arguments,
 *                      used to initialize argv_buf,
 *      ARGV_BUF_LEN    the length of ARGV_BUF,
 *      ARGC            the number of arguments in ARGV_BUF,
 *      INIT_MY_ARGV    a C statement that initializes my_argv with
 *                      pointers into argv_buf.
 *
 * USE_CTRLX
 *  Indicates that PL_origfilename should be reset to $^X, and $^X set
 *  to
 *      CTRL_X          the new value for $^X.
 *
 * USE_SUBFILE
 *  Indicates that a perl script has been appended to the exe, and it
 *  should be loaded using :subfile. Requires
 *      OFFSET          the offset from the end of the exe of the start
 *                      of the appended script.
 *
 * USE_ZIP
 *  A zipfile has been appended to the exe, and it should be prepended
 *  to @INC.
 *
 * USE_ZIP_SCRIPT
 *  The appended zipfile includes the script to be run as its
 *  'script.pl' member.
 *
 * NEED_INIT_WIN32CORE
 *  xsinit must call init_Win32CORE.
 *
 * NEED_MY_XSINIT
 *  We have work to do at xsinit time, so replace perl's xsinit with out
 *  own.
 *
 * NEED_PREAMBLE
 *  We have work to do at PL_preambleav time, so install an XSUB and
 *  call it from PL_preambleav.
 *
 * NEED_TAINT
 *  We are loading code that has been appended to the exe, so bail out
 *  if we are in taint mode. This requires
 *      TAINT_TYPE      a string describing what has been appended.
 */

#ifdef USE_SUBFILE
# define NEED_PREAMBLE
# define NEED_TAINT
# define TAINT_TYPE "script"
#endif

#ifdef USE_ZIP
# define NEED_MY_XSINIT
# define NEED_TAINT
# define TAINT_TYPE "zip"
#endif

#ifdef USE_ZIP_SCRIPT
# define NEED_PREAMBLE
#endif

#ifdef NEED_PREAMBLE
# define NEED_MY_XSINIT
#endif

#ifdef USE_CTRLX
# define NEED_MY_XSINIT
#endif

#ifdef NEED_MY_XSINIT
static void my_xsinit(pTHX);
static XSINIT_t     real_xsinit;
#endif

#ifdef USE_MY_ARGV
static char         argv_buf[sizeof(ARGV_BUF)] = ARGV_BUF;
#endif

#ifdef NEED_PREAMBLE
XS(XS_ExtUtils_PerlToExe_preamble);
#endif

#define PL_rsfp (PL_parser->rsfp)

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
#ifdef USE_MY_ARGV
    int   my_argc;
    char *my_argv[ARGC + argc];

    my_argv[0] = argv[0];
    INIT_MY_ARGV;

    /* argv has an extra "\\0" on the end, so we can go all 
       the way up to argv[argc] */

    for (my_argc = 0; my_argc < argc; my_argc++) {
        my_argv[my_argc + ARGC] = argv[my_argc + 1];
    }

    my_argc += ARGC - 1;
#else
# define my_argv argv
# define my_argc argc
#endif

#ifdef NEED_MY_XSINIT
    real_xsinit = xsinit;
#else
# define my_xsinit xsinit
#endif

    return perl_parse(interp, my_xsinit, my_argc, my_argv, env);

#undef my_argv
#undef my_argc
#undef my_xsinit
}

#ifdef NEED_MY_XSINIT

void
my_xsinit(pTHX)
{
    dVAR;
    static const char file[] = __FILE__;

#ifdef USE_CTRLX
    GV *ctrlXgv;
    SV *ctrlX;
#endif

#ifdef USE_SUBFILE
    if (PL_preprocess)
        croak("Can't use -P with pl2exe");
#endif

#ifdef NEED_INIT_WIN32CORE
    init_Win32CORE(aTHX);
#endif

#ifdef USE_ZIP
    pl2exe_boot_zip(aTHX);
#endif

#ifdef NEED_PREAMBLE
    newXS("ExtUtils::PerlToExe::preamble",
        XS_ExtUtils_PerlToExe_preamble,
        file);

    if (!PL_preambleav)
        PL_preambleav = newAV();
    av_push(PL_preambleav, 
        newSVpvs("BEGIN { ExtUtils::PerlToExe::preamble() }"));
#endif

#ifdef NEED_TAINT
    TAINT;
    TAINT_PROPER("appended " TAINT_TYPE);
    TAINT_NOT;
#endif

#ifdef USE_CTRLX
    ctrlXgv = gv_fetchpvs("\030", GV_NOTQUAL, SVt_PV);
    ctrlX   = GvSV(ctrlXgv);

    /*
     * We can't reopen PL_rsfp yet as it hasn't been set (the file is
     * open, it's just in an auto variable in S_parse_body). However,
     * it's easier to fixup the name here, before gv_fetch_file gets
     * called on it.
     */

    PL_origfilename = savepv(SvPV_nolen(ctrlX));
    CopFILE_free(PL_curcop);
    CopFILE_set(PL_curcop, PL_origfilename);

    sv_setpv(ctrlX, CTRL_X);
    SvTAINTED_on(ctrlX);
#endif

#ifdef USE_ZIP
    pl2exe_load_zip(aTHX_ PL_origfilename);
#endif

    real_xsinit(aTHX);
}

#endif /* NEED_MY_XSINIT */

#ifdef NEED_PREAMBLE

XS(XS_ExtUtils_PerlToExe_preamble)
{
    dVAR;
    dXSARGS;
#ifdef USE_ZIP_SCRIPT
    SV *scriptsv;
    IO *scriptio;
#endif

#ifdef USE_SUBFILE
    Perl_load_module(aTHX_ 0, newSVpvs("PerlIO::subfile"), NULL, NULL);

    PerlIO_close(PL_rsfp);
    PL_rsfp = PerlIO_open(PL_origfilename, "r");
    PerlIO_seek(PL_rsfp, -OFFSET, SEEK_END);

    PerlIO_apply_layers(aTHX_ PL_rsfp, "r", ":subfile");
#endif

#ifdef USE_ZIP_SCRIPT
    scriptsv = eval_pv("$INC[0]->INC('script.pl')", 1);
    if (!SvOK(scriptsv))
        croak("can't find 'script.pl' in %s", PL_origfilename);

    scriptio = sv_2io(scriptsv);
    if (!scriptio || !IoIFP(scriptio))
        croak("can't load 'script.pl' from %s", PL_origfilename);

    PL_rsfp = IoIFP(scriptio);
#endif

}

#endif /* NEED_PREAMBLE */
