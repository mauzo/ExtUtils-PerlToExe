#ifndef _PL2EXE_H
#define _PL2EXE_H

#include "p2econfig.h"

#ifdef PERL_IN_MINIPERLMAIN_C

# ifdef NEED_PERLAPI_H
#  include "perlapi.h"
# endif

# ifdef NEED_NO_PUC
#  undef PERL_UNUSED_CONTEXT
#  define PERL_UNUSED_CONTEXT dNOOP
# endif

# undef perl_parse
# define perl_parse pl2exe_perl_parse

#endif /* PERL_IN_MINIPERLMAIN_C */

int pl2exe_perl_parse(
    PerlInterpreter* interp, 
    XSINIT_t xsinit, 
    int argc, char **argv, char **env);

void pl2exe_boot_zip(pTHX);
void pl2exe_load_zip(pTHX_ const char *file);

#endif /* _PL2EXE_H */
