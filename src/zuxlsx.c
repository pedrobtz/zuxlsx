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
 *
 * Nothing here calls Rf_error(). Both entry points return a two-element list
 * (status, value), and R turns a non-"ok" status into a classed condition.
 * That is the convention the zu* packages share, and it matters more here than
 * in a pure-C package: Rf_error() longjmps past every free(), and an XLSX read
 * holds a ZIP handle, an Expat parser and -- later -- column builders at once.
 */
#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include <expat.h>
#include <miniz.h>
#include <xlsxio_read.h>
#include <xlsxio_version.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Status strings, matched by name in R/conditions.R. Kept as strings rather
   than an enum crossing the boundary so that adding one cannot silently
   renumber the others. */
static const char *const STATUS_OK = "ok";
static const char *const STATUS_ZIP_OPEN = "zip_open";
static const char *const STATUS_NO_SHEETS = "ooxml_no_sheets";
static const char *const STATUS_MEMORY = "memory";
static const char *const STATUS_BAD_PATH = "bad_path";
static const char *const STATUS_NO_SHEET = "sheet_not_found";
static const char *const STATUS_OLE2 = "format_ole2";
static const char *const STATUS_XLSB = "format_xlsb";
static const char *const STATUS_XML = "xml_malformed";

static SEXP result(const char *status, SEXP value) {
  const char *fields[] = {"status", "value", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SET_VECTOR_ELT(out, 0, Rf_mkString(status));
  SET_VECTOR_ELT(out, 1, value == NULL ? R_NilValue : value);
  UNPROTECT(1);
  return out;
}

/* Sheet names arrive one per callback and the count is not known up front, so
   they are collected in plain C memory. Deliberately not R memory: growing an
   R vector inside the callback would allocate while xlsxio holds the ZIP
   handle and the parser, and an allocation failure there longjmps straight out
   of the C stack that owns them. */
typedef struct {
  char **names;
  size_t n;
  size_t size;
  int oom;
} sheet_list;

static void sheet_list_free(sheet_list *sheets) {
  if (sheets == NULL) {
    return;
  }
  if (sheets->names != NULL) {
    for (size_t i = 0; i < sheets->n; i++) {
      free(sheets->names[i]);
    }
    free(sheets->names);
  }
  sheets->names = NULL;
  sheets->n = 0;
  sheets->size = 0;
}

/* The list outlives any single R allocation below by belonging to an external
   pointer with an eager finalizer, so an error unwinding out of Rf_mkCharCE()
   still frees it. */
static void sheet_list_finalizer(SEXP ptr) {
  sheet_list *sheets = (sheet_list *)R_ExternalPtrAddr(ptr);
  if (sheets != NULL) {
    sheet_list_free(sheets);
    free(sheets);
    R_ClearExternalPtr(ptr);
  }
}

/* Returns non-zero to abort the walk, which xlsxio honours by stopping the
   parser (see xlsxioread_list_sheets_callback_fn). An allocation failure
   therefore ends the read rather than truncating the answer silently. */
static int collect_sheet(const char *name, void *data) {
  sheet_list *sheets = (sheet_list *)data;
  char *copy;
  size_t len;

  if (sheets->n == sheets->size) {
    size_t size = sheets->size < 8 ? 8 : sheets->size * 2;
    char **grown;
    if (size > SIZE_MAX / sizeof(char *)) {
      sheets->oom = 1;
      return 1;
    }
    grown = (char **)realloc(sheets->names, size * sizeof(char *));
    if (grown == NULL) {
      sheets->oom = 1;
      return 1;
    }
    sheets->names = grown;
    sheets->size = size;
  }

  if (name == NULL) {
    name = "";
  }
  len = strlen(name);
  copy = (char *)malloc(len + 1);
  if (copy == NULL) {
    sheets->oom = 1;
    return 1;
  }
  memcpy(copy, name, len + 1);
  sheets->names[sheets->n++] = copy;
  return 0;
}

/* ------------------------------------------------------------------------ */
/* Telling "a file we cannot read" from "a broken file".
 *
 * Two formats reach this reader looking like failures when they are nothing
 * of the kind, and reporting them as corruption sends the caller looking for
 * a problem that is not there.
 *
 * An encrypted workbook is not a ZIP at all: password-to-open wraps the
 * package in an OLE2/CFB container, which is also what a legacy .xls is. The
 * eight byte signature identifies the container but not which of the two it
 * holds -- that needs the CFB directory, which is most of the work of reading
 * one, so the message names both possibilities rather than guessing.
 *
 * An .xlsb is a ZIP, and an OPC package, with XML content types and
 * relationships. Only the workbook and worksheet parts differ: BIFF12 binary
 * records rather than XML, so xlsxio finds no part of the content type it
 * wants and the workbook looks empty. Recognising xl/workbook.bin is enough to
 * say so, and costs nothing on the path where a workbook reads normally. */

static int file_is_ole2(const char *file) {
  static const unsigned char CFB_MAGIC[8] = {
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
  };
  unsigned char head[8];
  size_t got;
  FILE *fp = fopen(file, "rb");
  if (fp == NULL) {
    return 0;
  }
  got = fread(head, 1, sizeof(head), fp);
  fclose(fp);
  return got == sizeof(head) && memcmp(head, CFB_MAGIC, sizeof(head)) == 0;
}

/* Only asked once a workbook has already failed to declare a worksheet, so
   the second open costs nothing in the normal case. */
static int file_is_xlsb(const char *file) {
  mz_zip_archive zip;
  mz_uint32 index;
  int found = 0;

  memset(&zip, 0, sizeof(zip));
  if (!mz_zip_reader_init_file(&zip, file, 0)) {
    return 0;
  }
  if (mz_zip_reader_locate_file_v2(&zip, "xl/workbook.bin", NULL, 0, &index)) {
    found = 1;
  }
  mz_zip_reader_end(&zip);
  return found;
}

/* Which part, if any, is not well-formed XML.
 *
 * Asked only once a workbook has already failed to declare a worksheet, so
 * the cost is irrelevant and the answer is the difference between "this file
 * is not a workbook" and "xl/workbook.xml is broken at line 4". xlsxio does
 * not report why its parse produced nothing, but Expat and miniz are both
 * linked here directly, so the question can be asked without it.
 *
 * Only the two parts that must be well-formed for a workbook to be found are
 * checked. A malformed worksheet is a different failure, reached later, and
 * is not what this path is explaining. */
static int first_malformed_part(const char *file, char *out, size_t outlen,
                                int *line) {
  static const char *const PARTS[] = {"[Content_Types].xml", "xl/workbook.xml"};
  mz_zip_archive zip;
  size_t i;
  int found = 0;

  memset(&zip, 0, sizeof(zip));
  if (!mz_zip_reader_init_file(&zip, file, 0)) {
    return 0;
  }
  for (i = 0; i < sizeof(PARTS) / sizeof(PARTS[0]); i++) {
    size_t size = 0;
    void *buf;
    mz_uint32 index;
    XML_Parser parser;

    if (!mz_zip_reader_locate_file_v2(&zip, PARTS[i], NULL, 0, &index)) {
      continue;
    }
    buf = mz_zip_reader_extract_to_heap(&zip, index, &size, 0);
    if (buf == NULL) {
      continue;
    }
    parser = XML_ParserCreate(NULL);
    if (parser == NULL) {
      mz_free(buf);
      continue;
    }
    if (XML_Parse(parser, (const char *)buf, (int)size, 1) == XML_STATUS_ERROR) {
      size_t n = strlen(PARTS[i]);
      if (n >= outlen) {
        n = outlen - 1;
      }
      memcpy(out, PARTS[i], n);
      out[n] = '\0';
      *line = (int)XML_GetCurrentLineNumber(parser);
      found = 1;
    }
    XML_ParserFree(parser);
    mz_free(buf);
    if (found) {
      break;
    }
  }
  mz_zip_reader_end(&zip);
  return found;
}

SEXP C_xlsx_sheets(SEXP path) {
  const char *file;
  sheet_list *sheets;
  xlsxioreader reader;
  SEXP bag, out, res;
  size_t i;

  /* R validates the argument before calling, but the registered symbol is
     reachable from the namespace, so a wrong type must not be a crash. */
  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING) {
    return result(STATUS_BAD_PATH, R_NilValue);
  }

  /* Before anything is held: this can allocate and can fail. */
  file = Rf_translateCharUTF8(STRING_ELT(path, 0));

  sheets = (sheet_list *)calloc(1, sizeof(sheet_list));
  if (sheets == NULL) {
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(sheets, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, sheet_list_finalizer, TRUE);

  /* An OLE2 container will not open as a ZIP, so this has to be asked before
     the reader is handed the path or the answer is "corrupt archive". */
  if (file_is_ole2(file)) {
    sheet_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_OLE2, R_NilValue);
  }

  /* No R allocation between here and xlsxioread_close(): while the reader is
     open it owns a miniz archive handle and an Expat parser, and neither is
     reachable from R to be cleaned up if something unwound past them. */
  reader = xlsxioread_open(file);
  if (reader == NULL) {
    sheet_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  xlsxioread_list_sheets(reader, collect_sheet, sheets);
  xlsxioread_close(reader);

  if (sheets->oom) {
    sheet_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  /* A workbook has at least one worksheet: CT_Sheets requires 1..n. Zero here
     means the ZIP opened but is not a workbook -- no [Content_Types].xml, no
     workbook part, or a workbook with no <sheet> elements. Reporting that as
     an empty character vector would make a wrong file look like an odd one. */
  if (sheets->n == 0) {
    char part[64];
    int line = 0;
    int xlsb = file_is_xlsb(file);
    const char *status = STATUS_NO_SHEETS;
    SEXP detail = R_NilValue;

    if (xlsb) {
      status = STATUS_XLSB;
    } else if (first_malformed_part(file, part, sizeof(part), &line)) {
      status = STATUS_XML;
    }
    sheet_list_finalizer(bag);
    if (status == STATUS_XML) {
      const char *fields[] = {"part", "line", ""};
      detail = PROTECT(Rf_mkNamed(VECSXP, fields));
      SET_VECTOR_ELT(detail, 0, Rf_mkString(part));
      SET_VECTOR_ELT(detail, 1, Rf_ScalarInteger(line));
      res = PROTECT(result(status, detail));
      UNPROTECT(3);
      return res;
    }
    UNPROTECT(1);
    return result(status, R_NilValue);
  }

  out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)sheets->n));
  for (i = 0; i < sheets->n; i++) {
    SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(sheets->names[i], CE_UTF8));
  }
  sheet_list_finalizer(bag);

  /* result() allocates, so out stays protected across it. */
  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(3);
  return res;
}

/* ------------------------------------------------------------------------ */
/* Cell reading (design sections 12-13).
 *
 * The cell event model lives here rather than in xlsxio: xlsxio reports a
 * value as text, and -- with the vendored 0003 patch -- the OOXML type and
 * whether the number format is a date. Turning that into the typed cell
 * design section 13 describes is this layer's job.
 *
 * Cells are accumulated in plain C memory for the same reason sheet names
 * are: the worksheet iterator holds a ZIP handle and a suspended Expat
 * parser for the whole walk, and an R allocation failing mid-walk would
 * longjmp past both. R vectors are built only once everything is closed. */

typedef enum {
  ZU_CELL_BLANK = 0,
  ZU_CELL_NUMBER = 1,
  ZU_CELL_STRING = 2,
  ZU_CELL_BOOLEAN = 3,
  ZU_CELL_ERROR = 4,
  ZU_CELL_DATE = 5
} zu_cell_type;

typedef struct {
  size_t *row;
  size_t *col;
  int *type;
  char **text;
  double *number;
  size_t n;
  size_t size;
  int oom;
} cell_list;

static void cell_list_free(cell_list *cells) {
  size_t i;
  if (cells == NULL) {
    return;
  }
  if (cells->text != NULL) {
    for (i = 0; i < cells->n; i++) {
      free(cells->text[i]);
    }
    free(cells->text);
  }
  free(cells->row);
  free(cells->col);
  free(cells->type);
  free(cells->number);
  cells->text = NULL;
  cells->row = NULL;
  cells->col = NULL;
  cells->type = NULL;
  cells->number = NULL;
  cells->n = 0;
  cells->size = 0;
}

static void cell_list_finalizer(SEXP ptr) {
  cell_list *cells = (cell_list *)R_ExternalPtrAddr(ptr);
  if (cells != NULL) {
    cell_list_free(cells);
    free(cells);
    R_ClearExternalPtr(ptr);
  }
}

/* Grows every parallel array together, so a partial growth cannot leave the
   arrays disagreeing about how many cells there are. */
static int cell_list_grow(cell_list *cells) {
  size_t size = cells->size < 64 ? 64 : cells->size * 2;
  size_t *row, *col;
  int *type;
  char **text;
  double *number;

  if (size > SIZE_MAX / sizeof(double)) {
    return 1;
  }
  if ((row = (size_t *)realloc(cells->row, size * sizeof(size_t))) == NULL) {
    return 1;
  }
  cells->row = row;
  if ((col = (size_t *)realloc(cells->col, size * sizeof(size_t))) == NULL) {
    return 1;
  }
  cells->col = col;
  if ((type = (int *)realloc(cells->type, size * sizeof(int))) == NULL) {
    return 1;
  }
  cells->type = type;
  if ((text = (char **)realloc(cells->text, size * sizeof(char *))) == NULL) {
    return 1;
  }
  cells->text = text;
  if ((number = (double *)realloc(cells->number, size * sizeof(double))) == NULL) {
    return 1;
  }
  cells->number = number;
  cells->size = size;
  return 0;
}

static int cell_list_push(cell_list *cells, size_t row, size_t col, int type,
                          const char *text, double number) {
  char *copy = NULL;
  if (cells->n == cells->size && cell_list_grow(cells) != 0) {
    cells->oom = 1;
    return 1;
  }
  if (text != NULL) {
    size_t len = strlen(text);
    if ((copy = (char *)malloc(len + 1)) == NULL) {
      cells->oom = 1;
      return 1;
    }
    memcpy(copy, text, len + 1);
  }
  cells->row[cells->n] = row;
  cells->col[cells->n] = col;
  cells->type[cells->n] = type;
  cells->text[cells->n] = copy;
  cells->number[cells->n] = number;
  cells->n++;
  return 0;
}

/* Maps what xlsxio reports onto the design section 13 type. A date is not an
   OOXML type of its own: except for the rare t="d", it is a number whose
   style carries a date format, which is why the format table is consulted
   rather than the type alone. */
static int classify_cell(int xlsxio_type, int is_date, const char *value,
                         double *number) {
  char *end = NULL;
  *number = NA_REAL;

  if (value == NULL || *value == 0) {
    return ZU_CELL_BLANK;
  }
  switch (xlsxio_type) {
    case XLSXIOREAD_CELLTYPE_BOOLEAN:
      *number = (value[0] == '0') ? 0.0 : 1.0;
      return ZU_CELL_BOOLEAN;
    case XLSXIOREAD_CELLTYPE_ERROR:
      return ZU_CELL_ERROR;
    case XLSXIOREAD_CELLTYPE_STRING:
      return ZU_CELL_STRING;
    case XLSXIOREAD_CELLTYPE_DATE:
      return ZU_CELL_DATE;
    case XLSXIOREAD_CELLTYPE_NUMBER:
    default:
      break;
  }
  /* A number, or a date stored as one. strtod is the only conversion: the
     serial value is kept as written and interpreted in R, where the 1900 and
     1904 epochs can be told apart using the workbook's own setting. */
  *number = strtod(value, &end);
  if (end == value || (end != NULL && *end != 0)) {
    *number = NA_REAL;
    return ZU_CELL_STRING;
  }
  return is_date ? ZU_CELL_DATE : ZU_CELL_NUMBER;
}

SEXP C_xlsx_cells(SEXP path, SEXP sheet) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  xlsxioreader reader;
  xlsxioreadersheet worksheet;
  SEXP bag, out, res;
  SEXP r_row, r_col, r_type, r_text, r_number, r_epoch;
  size_t i;
  size_t rownr = 0;
  int date1904 = 0;

  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING ||
      TYPEOF(sheet) != STRSXP || XLENGTH(sheet) < 1 ||
      STRING_ELT(sheet, 0) == NA_STRING) {
    return result(STATUS_BAD_PATH, R_NilValue);
  }
  file = Rf_translateCharUTF8(STRING_ELT(path, 0));
  sheetname = Rf_translateCharUTF8(STRING_ELT(sheet, 0));

  cells = (cell_list *)calloc(1, sizeof(cell_list));
  if (cells == NULL) {
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(cells, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, cell_list_finalizer, TRUE);

  if (file_is_ole2(file)) {
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_OLE2, R_NilValue);
  }

  /* No R allocation until xlsxioread_close(). */
  reader = xlsxioread_open(file);
  if (reader == NULL) {
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  worksheet = xlsxioread_sheet_open(reader, sheetname, XLSXIOREAD_SKIP_NONE);
  if (worksheet == NULL) {
    xlsxioread_close(reader);
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_NO_SHEET, R_NilValue);
  }

  while (xlsxioread_sheet_next_row(worksheet)) {
    size_t colnr = 0;
    char *value;
    rownr++;
    /* NULL means end of row, not a blank cell: a blank arrives as a
       non-NULL empty string. Treating NULL as a value would never
       terminate the row. */
    while ((value = xlsxioread_sheet_next_cell(worksheet)) != NULL) {
      double number;
      int type = classify_cell(xlsxioread_sheet_last_cell_type(worksheet),
                               xlsxioread_sheet_last_cell_is_date(worksheet),
                               value, &number);
      colnr++;
      if (cell_list_push(cells, rownr, colnr, type, value, number) != 0) {
        free(value);
        break;
      }
      free(value);
      if (cells->oom) {
        break;
      }
    }
    if (cells->oom) {
      break;
    }
  }
  date1904 = xlsxioread_sheet_date1904(worksheet);
  xlsxioread_sheet_close(worksheet);
  xlsxioread_close(reader);

  if (cells->oom) {
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }

  out = PROTECT(Rf_allocVector(VECSXP, 6));
  r_row = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)cells->n));
  r_col = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)cells->n));
  r_type = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)cells->n));
  r_text = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)cells->n));
  r_number = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)cells->n));
  r_epoch = PROTECT(Rf_ScalarLogical(date1904));
  for (i = 0; i < cells->n; i++) {
    REAL(r_row)[i] = (double)cells->row[i];
    REAL(r_col)[i] = (double)cells->col[i];
    INTEGER(r_type)[i] = cells->type[i];
    SET_STRING_ELT(r_text, (R_xlen_t)i,
                   cells->text[i] == NULL
                     ? NA_STRING
                     : Rf_mkCharCE(cells->text[i], CE_UTF8));
    REAL(r_number)[i] = cells->number[i];
  }
  SET_VECTOR_ELT(out, 0, r_row);
  SET_VECTOR_ELT(out, 1, r_col);
  SET_VECTOR_ELT(out, 2, r_type);
  SET_VECTOR_ELT(out, 3, r_text);
  SET_VECTOR_ELT(out, 4, r_number);
  SET_VECTOR_ELT(out, 5, r_epoch);
  cell_list_finalizer(bag);

  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(9);
  return res;
}

SEXP C_zuxlsx_native(void) {
  const char *fields[] = {"xlsxio", "expat", "miniz", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SEXP res;

  SET_VECTOR_ELT(out, 0, Rf_mkString(XLSXIO_VERSION_STRING));
  /* A real call into libzuxml.a, not a macro: a header that is on the path
     while the archive is not would still compile, and this is what makes
     that fail at link time instead. */
  SET_VECTOR_ELT(out, 1, Rf_mkString(XML_ExpatVersion()));
  SET_VECTOR_ELT(out, 2, Rf_mkString(MZ_VERSION));

  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(2);
  return res;
}
