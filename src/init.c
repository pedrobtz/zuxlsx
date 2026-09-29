#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include "agile.h"

SEXP C_xlsx_sheets(SEXP path, SEXP password);
SEXP C_xlsx_cells(SEXP path, SEXP sheet, SEXP password);
SEXP C_xlsx_read_cells(SEXP path, SEXP sheet, SEXP callback, SEXP env, SEXP chunk,
                       SEXP password);
SEXP C_read_xlsx(SEXP path, SEXP sheet, SEXP col_names, SEXP bounds, SEXP password);
SEXP C_zuxlsx_native(void);
SEXP C_agile_decrypt(SEXP params, SEXP password, SEXP package);
SEXP C_cfb_streams(SEXP bytes, SEXP names);
SEXP C_encryption_info(SEXP stream);
SEXP C_decrypt_ole2(SEXP bytes, SEXP password);

static const R_CallMethodDef call_entries[] = {
  {"C_xlsx_sheets",   (DL_FUNC) &C_xlsx_sheets,   2},
  {"C_xlsx_cells",    (DL_FUNC) &C_xlsx_cells,    3},
  {"C_xlsx_read_cells", (DL_FUNC) &C_xlsx_read_cells, 6},
  {"C_read_xlsx",     (DL_FUNC) &C_read_xlsx,     5},
  {"C_zuxlsx_native", (DL_FUNC) &C_zuxlsx_native, 0},
  {"C_agile_decrypt", (DL_FUNC) &C_agile_decrypt, 3},
  {"C_cfb_streams",   (DL_FUNC) &C_cfb_streams,   2},
  {"C_encryption_info", (DL_FUNC) &C_encryption_info, 1},
  {"C_decrypt_ole2",  (DL_FUNC) &C_decrypt_ole2,  2},
  {NULL, NULL, 0}
};

/* libzucrypt.a is linked statically, so this DLL owns its backend: one
   reference taken on load and dropped on unload (zucrypt.h, "Shape 2"). Not
   per call -- zuc_init() is reference counted but not free, and a decryption
   must not be able to find the backend torn down under it. A failure is
   remembered rather than raised, since R_init_ must not longjmp. */
void R_init_zuxlsx(DllInfo *dll) {
  R_registerRoutines(dll, NULL, call_entries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  agile_backend_init();
}

void R_unload_zuxlsx(DllInfo *dll) {
  (void) dll;
  agile_backend_shutdown();
}
