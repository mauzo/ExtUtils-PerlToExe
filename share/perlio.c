#include "EXTERN.h"
#define PERL_IN_PERLIO_C
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"
#include "pl2exe.h"

PerlIO_funcs *
PerlIO_find_layer(pTHX_ const char *name, STRLEN len, int load)
{
    dVAR;
    IV i;

    if ((SSize_t) len <= 0)
	len = strlen(name);
    for (i = 0; i < PL_known_layers->cur; i++) {
	PerlIO_funcs * const f = PL_known_layers->array[i].funcs;
	if (memEQ(f->name, name, len) && f->name[len] == 0) {
	    PerlIO_debug("%.*s => %p\n", (int) len, name, (void*)f);
	    return f;
	}
    }
    if (load && PL_subname && PL_def_layerlist
	&& PL_def_layerlist->cur >= 2) {
	if (PL_in_load_module) {
	    Perl_croak(aTHX_ "Recursive call to Perl_load_module in PerlIO_find_layer");
	    return NULL;
	} else {
	    SV * const pkgsv = newSVpvs("PerlIO");
	    SV * const layer = newSVpvn(name, len);
	    CV * const cv    = Perl_get_cvn_flags(aTHX_ STR_WITH_LEN("PerlIO::Layer::NoWarnings"), 0);
	    ENTER;
	    SAVEINT(PL_in_load_module);
	    if (cv) {
		SAVEGENERICSV(PL_warnhook);
		PL_warnhook = (SV *) (SvREFCNT_inc_simple_NN(cv));
	    }
	    PL_in_load_module++;
	    /*
	     * The two SVs are magically freed by load_module
	     */
	    Perl_load_module(aTHX_ 0, pkgsv, NULL, layer, NULL);
	    PL_in_load_module--;
	    LEAVE;
	    return PerlIO_find_layer(aTHX_ name, len, 0);
	}
    }
    PerlIO_debug("Cannot find %.*s\n", (int) len, name);
    return NULL;
}

