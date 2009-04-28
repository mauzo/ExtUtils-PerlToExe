#ifndef _PL2EXE_H
#define _PL2EXE_H

#ifdef PERL_IN_MINIPERLMAIN_C
#undef perl_parse
#define perl_parse pl2exe_perl_parse
#endif

int pl2exe_perl_parse(
    PerlInterpreter* interp, 
    XSINIT_t xsinit, 
    int argc, char **argv, char **env);

#endif
