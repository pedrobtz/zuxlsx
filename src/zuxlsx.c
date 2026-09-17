/* The smallest surface that proves the LinkingTo wiring works end to end.
 *
 * This is not the start of the public API -- read_xlsx(), the cell reader and
 * the column builders in design sections 12-14 come later, and will not go
 * through xlsxio's string callbacks the way this does. It exists so that a
 * broken link is a failing test rather than something discovered in the first
 * real feature:
 *
 *   zuxlsx_native()  calls Expat directly, so it fails to link without
 *                    libzuxml.a, and reports what the headers on the
 *                    LinkingTo path say.
 *   xlsx_sheets()    goes through xlsxio, which means miniz opens the ZIP
 *                    (libzukomp.a) and Expat parses xl/workbook.xml
 *                    (libzuxml.a). Both archives, on a real file.
 */
#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include <expat.h>
#include <miniz.h>
#include <xlsxio_read.h>
#include <xlsxio_version.h>

#include <stdlib.h>
#include <string.h>

/* Sheet names arrive one per callback, and the count is not known up front.
   Collected into a growing list of R strings; see the PROTECT note below. */
typedef struct {
  SEXP names;      /* a character vector, grown geometrically */
  R_xlen_t n;      /* how many of its elements are filled */
  R_xlen_t size;
} sheet_list;

static int collect_sheet(const char *name, void *data) {
  sheet_list *sheets = (sheet_list *)data;

  if (sheets->n == sheets->size) {
    R_xlen_t size = sheets->size < 8 ? 8 : sheets->size * 2;
    SEXP grown = PROTECT(Rf_allocVector(STRSXP, size));
    for (R_xlen_t i = 0; i < sheets->n; i++) {
      SET_STRING_ELT(grown, i, STRING_ELT(sheets->names, i));
    }
    /* R_ReleaseObject/R_PreserveObject rather than PROTECT: this runs inside
       xlsxio's callback, below the .Call that will return the result, and the
       protection has to outlive each callback invocation. */
    R_PreserveObject(grown);
    R_ReleaseObject(sheets->names);
    sheets->names = grown;
    sheets->size = size;
    UNPROTECT(1);
  }

  SET_STRING_ELT(sheets->names, sheets->n++,
                 Rf_mkCharCE(name ? name : "", CE_UTF8));
  return 0;
}

SEXP C_xlsx_sheets(SEXP path) {
  const char *file = Rf_translateCharUTF8(STRING_ELT(path, 0));
  xlsxioreader reader = xlsxioread_open(file);
  sheet_list sheets;
  SEXP out;

  if (reader == NULL) {
    Rf_error("could not open '%s' as an xlsx workbook", file);
  }

  sheets.names = Rf_allocVector(STRSXP, 0);
  R_PreserveObject(sheets.names);
  sheets.n = 0;
  sheets.size = 0;

  xlsxioread_list_sheets(reader, collect_sheet, &sheets);
  xlsxioread_close(reader);

  out = PROTECT(Rf_allocVector(STRSXP, sheets.n));
  for (R_xlen_t i = 0; i < sheets.n; i++) {
    SET_STRING_ELT(out, i, STRING_ELT(sheets.names, i));
  }
  R_ReleaseObject(sheets.names);
  UNPROTECT(1);
  return out;
}

SEXP C_zuxlsx_native(void) {
  const char *fields[] = {"xlsxio", "expat", "miniz", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));

  SET_VECTOR_ELT(out, 0, Rf_mkString(XLSXIO_VERSION_STRING));
  /* A real call into libzuxml.a, not a macro: a header that is on the path
     while the archive is not would still compile, and this is what makes
     that fail at link time instead. */
  SET_VECTOR_ELT(out, 1, Rf_mkString(XML_ExpatVersion()));
  SET_VECTOR_ELT(out, 2, Rf_mkString(MZ_VERSION));

  UNPROTECT(1);
  return out;
}
