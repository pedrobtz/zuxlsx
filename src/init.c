#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

SEXP C_xlsx_sheets(SEXP path);
SEXP C_zuxlsx_native(void);

static const R_CallMethodDef call_entries[] = {
  {"C_xlsx_sheets",   (DL_FUNC) &C_xlsx_sheets,   1},
  {"C_zuxlsx_native", (DL_FUNC) &C_zuxlsx_native, 0},
  {NULL, NULL, 0}
};

void R_init_zuxlsx(DllInfo *dll) {
  R_registerRoutines(dll, NULL, call_entries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
