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

/* The cells accumulated so far, as the five parallel vectors R assembles into
   a data frame, plus the workbook's epoch. Shared by the whole-sheet read and
   the callback read so that the two cannot describe a cell differently. */
static SEXP cells_to_list(const cell_list *cells, int date1904) {
  SEXP out, r_row, r_col, r_type, r_text, r_number, r_epoch;
  size_t i;

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
  UNPROTECT(7);
  return out;
}

/* An open reader and worksheet, owned by R rather than by the C stack.
 *
 * The whole-sheet read can keep these on the stack because nothing between
 * opening and closing them can longjmp. The callback read cannot: it calls an
 * R function while both are open, and that function may signal a condition,
 * be interrupted, or simply return from a restart -- any of which unwinds
 * straight past a close(). Handing ownership to an external pointer with a
 * registered finalizer is what makes that safe, and is the pattern design
 * section 15 asks for. */
typedef struct {
  xlsxioreader reader;
  xlsxioreadersheet sheet;
} reader_handle;

static void reader_handle_finalizer(SEXP ptr) {
  reader_handle *h = (reader_handle *)R_ExternalPtrAddr(ptr);
  if (h != NULL) {
    if (h->sheet != NULL) {
      xlsxioread_sheet_close(h->sheet);
      h->sheet = NULL;
    }
    if (h->reader != NULL) {
      xlsxioread_close(h->reader);
      h->reader = NULL;
    }
    free(h);
    R_ClearExternalPtr(ptr);
  }
}

SEXP C_xlsx_cells(SEXP path, SEXP sheet) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  xlsxioreader reader;
  xlsxioreadersheet worksheet;
  SEXP bag, out, res;
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

  out = PROTECT(cells_to_list(cells, date1904));
  cell_list_finalizer(bag);

  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(3);
  return res;
}

/* Reads a worksheet a chunk at a time, handing each chunk to an R function.
 *
 * The point of this entry is that the whole sheet is never held at once, so
 * unlike C_xlsx_cells it must call R while the archive and parser are open.
 * Both are therefore owned by external pointers with registered finalizers:
 * the callback may signal a condition or be interrupted, and either unwinds
 * past every close() and free() on this stack. Nothing here calls Rf_error()
 * itself, for the same reason it is avoided everywhere else.
 *
 * A callback returning FALSE stops the read. That is what makes this more
 * than a memory optimisation -- it is how a caller finds something in a large
 * sheet without paying for the rest of it. */
SEXP C_xlsx_read_cells(SEXP path, SEXP sheet, SEXP callback, SEXP env,
                       SEXP chunk) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  reader_handle *handle;
  SEXP bag, holder, res;
  size_t limit;
  size_t rownr = 0;
  int date1904 = 0;
  int stopped = 0;

  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING ||
      TYPEOF(sheet) != STRSXP || XLENGTH(sheet) < 1 ||
      STRING_ELT(sheet, 0) == NA_STRING ||
      TYPEOF(callback) != CLOSXP || TYPEOF(env) != ENVSXP ||
      TYPEOF(chunk) != INTSXP || XLENGTH(chunk) < 1 ||
      INTEGER(chunk)[0] == NA_INTEGER || INTEGER(chunk)[0] < 1) {
    return result(STATUS_BAD_PATH, R_NilValue);
  }
  file = Rf_translateCharUTF8(STRING_ELT(path, 0));
  sheetname = Rf_translateCharUTF8(STRING_ELT(sheet, 0));
  limit = (size_t)INTEGER(chunk)[0];

  if (file_is_ole2(file)) {
    return result(STATUS_OLE2, R_NilValue);
  }

  cells = (cell_list *)calloc(1, sizeof(cell_list));
  if (cells == NULL) {
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(cells, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, cell_list_finalizer, TRUE);

  handle = (reader_handle *)calloc(1, sizeof(reader_handle));
  if (handle == NULL) {
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  holder = PROTECT(R_MakeExternalPtr(handle, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(holder, reader_handle_finalizer, TRUE);

  handle->reader = xlsxioread_open(file);
  if (handle->reader == NULL) {
    reader_handle_finalizer(holder);
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  handle->sheet = xlsxioread_sheet_open(handle->reader, sheetname,
                                        XLSXIOREAD_SKIP_NONE);
  if (handle->sheet == NULL) {
    reader_handle_finalizer(holder);
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_NO_SHEET, R_NilValue);
  }
  date1904 = xlsxioread_sheet_date1904(handle->sheet);

  while (!stopped && xlsxioread_sheet_next_row(handle->sheet)) {
    size_t colnr = 0;
    char *value;
    rownr++;
    while ((value = xlsxioread_sheet_next_cell(handle->sheet)) != NULL) {
      double num;
      int type = classify_cell(xlsxioread_sheet_last_cell_type(handle->sheet),
                               xlsxioread_sheet_last_cell_is_date(handle->sheet),
                               value, &num);
      colnr++;
      if (cell_list_push(cells, rownr, colnr, type, value, num) != 0) {
        free(value);
        break;
      }
      free(value);
    }
    if (cells->oom) {
      break;
    }
    /* Emitted between rows, never inside one, so a chunk boundary can never
       fall in the middle of a row and split it across two callbacks. */
    if (cells->n >= limit) {
      SEXP arg = PROTECT(cells_to_list(cells, date1904));
      SEXP call = PROTECT(Rf_lang2(callback, arg));
      SEXP val = PROTECT(Rf_eval(call, env));
      stopped = (TYPEOF(val) == LGLSXP && XLENGTH(val) >= 1 &&
                 LOGICAL(val)[0] == FALSE);
      UNPROTECT(3);
      cell_list_free(cells);
    }
  }

  if (cells->oom) {
    reader_handle_finalizer(holder);
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }
  if (!stopped && cells->n > 0) {
    SEXP arg = PROTECT(cells_to_list(cells, date1904));
    SEXP call = PROTECT(Rf_lang2(callback, arg));
    SEXP val = PROTECT(Rf_eval(call, env));
    stopped = (TYPEOF(val) == LGLSXP && XLENGTH(val) >= 1 &&
               LOGICAL(val)[0] == FALSE);
    UNPROTECT(3);
  }

  reader_handle_finalizer(holder);
  cell_list_finalizer(bag);
  res = PROTECT(result(STATUS_OK, Rf_ScalarLogical(stopped)));
  UNPROTECT(3);
  return res;
}

/* ------------------------------------------------------------------------ */
/* Column building (design section 14).
 *
 * read_xlsx() used to receive the cells as R vectors and pivot them in R,
 * which meant the text of every cell crossed into R whether or not any column
 * needed it. On a 20000 by 10 sheet that text was 7.5 MB of a 12.8 MB
 * intermediate, and seven of the ten columns were numeric and threw it away.
 *
 * Deciding each column's type here instead means only what a column actually
 * is gets built: a numeric column emits doubles and its text is never
 * allocated in R at all. Fidelity is unaffected, which is the point of doing
 * it this way rather than streaming -- promotion to character still returns
 * each cell as it was written, because the text is still here in C when the
 * decision is made.
 *
 * The type rules mirror R's build_column() exactly, and the two are held
 * together by the same tests rather than by inspection. */

#define TYPEMASK(t) (1u << (t))

static int column_kind(unsigned int mask) {
  /* Nothing but blanks: logical NA, which promotes to anything without a
     coercion warning. */
  if (mask == 0u) {
    return ZU_CELL_BLANK;
  }
  if (mask == TYPEMASK(ZU_CELL_BOOLEAN)) {
    return ZU_CELL_BOOLEAN;
  }
  if (mask == TYPEMASK(ZU_CELL_NUMBER)) {
    return ZU_CELL_NUMBER;
  }
  if (mask == TYPEMASK(ZU_CELL_DATE)) {
    return ZU_CELL_DATE;
  }
  /* A string, a cell error, or any mixture: character. */
  return ZU_CELL_STRING;
}

SEXP C_read_xlsx(SEXP path, SEXP sheet, SEXP col_names, SEXP bounds) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  xlsxioreader reader;
  xlsxioreadersheet worksheet;
  SEXP bag, out, res, r_cols, r_header, r_isdate;
  size_t i;
  size_t rownr = 0;
  int date1904 = 0;
  int header = 0;
  double min_row = NA_REAL, max_row = NA_REAL;
  double min_col = NA_REAL, max_col = NA_REAL;
  double first_row = 0, last_row = 0;
  size_t ncol = 0, nrow = 0, body_first = 0;
  unsigned int *mask = NULL;
  int *kind = NULL;

  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING ||
      TYPEOF(sheet) != STRSXP || XLENGTH(sheet) < 1 ||
      STRING_ELT(sheet, 0) == NA_STRING ||
      TYPEOF(col_names) != LGLSXP || XLENGTH(col_names) < 1) {
    return result(STATUS_BAD_PATH, R_NilValue);
  }
  header = (LOGICAL(col_names)[0] == TRUE);
  if (bounds != R_NilValue) {
    if (TYPEOF(bounds) != REALSXP || XLENGTH(bounds) != 4) {
      return result(STATUS_BAD_PATH, R_NilValue);
    }
    min_row = REAL(bounds)[0];
    max_row = REAL(bounds)[1];
    min_col = REAL(bounds)[2];
    max_col = REAL(bounds)[3];
  }
  file = Rf_translateCharUTF8(STRING_ELT(path, 0));
  sheetname = Rf_translateCharUTF8(STRING_ELT(sheet, 0));

  if (file_is_ole2(file)) {
    return result(STATUS_OLE2, R_NilValue);
  }

  cells = (cell_list *)calloc(1, sizeof(cell_list));
  if (cells == NULL) {
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(cells, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, cell_list_finalizer, TRUE);

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
    while ((value = xlsxioread_sheet_next_cell(worksheet)) != NULL) {
      double num;
      int type = classify_cell(xlsxioread_sheet_last_cell_type(worksheet),
                               xlsxioread_sheet_last_cell_is_date(worksheet),
                               value, &num);
      colnr++;
      /* Cells outside the range are dropped here rather than after the fact,
         so a range never pays for the rest of the worksheet in memory. */
      if (!ISNA(min_row) && ((double)rownr < min_row || (double)rownr > max_row)) {
        free(value);
        continue;
      }
      if (!ISNA(min_col) && ((double)colnr < min_col || (double)colnr > max_col)) {
        free(value);
        continue;
      }
      if (cell_list_push(cells, rownr, colnr, type, value, num) != 0) {
        free(value);
        break;
      }
      free(value);
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
  if (cells->n == 0) {
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_OK, R_NilValue);
  }

  /* Shift so the top-left of the range is row 1, column 1. */
  if (!ISNA(min_row) || !ISNA(min_col)) {
    for (i = 0; i < cells->n; i++) {
      if (!ISNA(min_row)) cells->row[i] -= (size_t)min_row - 1;
      if (!ISNA(min_col)) cells->col[i] -= (size_t)min_col - 1;
    }
  }

  /* A range asks for its own rectangle whether or not cells fill it; without
     one the extent is whatever the worksheet used. Rows are spanned rather
     than taken from the rows that carry a cell, so an omitted row stays a
     row -- see R's build_column() for why that matters. */
  first_row = (double)cells->row[0];
  last_row = first_row;
  for (i = 0; i < cells->n; i++) {
    if ((double)cells->row[i] < first_row) first_row = (double)cells->row[i];
    if ((double)cells->row[i] > last_row) last_row = (double)cells->row[i];
    if (cells->col[i] > ncol) ncol = cells->col[i];
  }
  if (!ISNA(min_row)) {
    first_row = 1;
    last_row = max_row - min_row + 1;
  }
  if (!ISNA(min_col)) {
    ncol = (size_t)(max_col - min_col + 1);
  }
  body_first = (size_t)first_row + (header ? 1u : 0u);
  nrow = (last_row >= (double)body_first) ? (size_t)(last_row - (double)body_first + 1) : 0;

  mask = (unsigned int *)calloc(ncol, sizeof(unsigned int));
  kind = (int *)calloc(ncol, sizeof(int));
  if (mask == NULL || kind == NULL) {
    free(mask);
    free(kind);
    cell_list_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  for (i = 0; i < cells->n; i++) {
    if (cells->row[i] < body_first || cells->type[i] == ZU_CELL_BLANK) {
      continue;
    }
    mask[cells->col[i] - 1] |= TYPEMASK(cells->type[i]);
  }
  for (i = 0; i < ncol; i++) {
    kind[i] = column_kind(mask[i]);
  }

  r_cols = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)ncol));
  r_header = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)ncol));
  r_isdate = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)ncol));
  for (i = 0; i < ncol; i++) {
    SEXP col;
    R_xlen_t k;
    SET_STRING_ELT(r_header, (R_xlen_t)i, NA_STRING);
    LOGICAL(r_isdate)[i] = (kind[i] == ZU_CELL_DATE);
    switch (kind[i]) {
      case ZU_CELL_BOOLEAN:
      case ZU_CELL_BLANK:
        col = Rf_allocVector(LGLSXP, (R_xlen_t)nrow);
        for (k = 0; k < (R_xlen_t)nrow; k++) LOGICAL(col)[k] = NA_LOGICAL;
        break;
      case ZU_CELL_STRING:
        col = Rf_allocVector(STRSXP, (R_xlen_t)nrow);
        for (k = 0; k < (R_xlen_t)nrow; k++) SET_STRING_ELT(col, k, NA_STRING);
        break;
      default:
        col = Rf_allocVector(REALSXP, (R_xlen_t)nrow);
        for (k = 0; k < (R_xlen_t)nrow; k++) REAL(col)[k] = NA_REAL;
        break;
    }
    SET_VECTOR_ELT(r_cols, (R_xlen_t)i, col);
  }

  for (i = 0; i < cells->n; i++) {
    size_t c = cells->col[i] - 1;
    SEXP col;
    R_xlen_t at;
    if (c >= ncol) {
      continue;
    }
    if (header && cells->row[i] == (size_t)first_row) {
      if (cells->text[i] != NULL && cells->text[i][0] != '\0') {
        SET_STRING_ELT(r_header, (R_xlen_t)c, Rf_mkCharCE(cells->text[i], CE_UTF8));
      }
      continue;
    }
    if (cells->row[i] < body_first) {
      continue;
    }
    at = (R_xlen_t)(cells->row[i] - body_first);
    if (at < 0 || at >= (R_xlen_t)nrow || cells->type[i] == ZU_CELL_BLANK) {
      continue;
    }
    col = VECTOR_ELT(r_cols, (R_xlen_t)c);
    switch (kind[c]) {
      case ZU_CELL_BOOLEAN:
        LOGICAL(col)[at] = (cells->number[i] != 0.0);
        break;
      case ZU_CELL_STRING:
        /* The cell as it was written. Reformatting the stored double here
           would turn "1.50" into "1.5" in any column that promotes. */
        if (cells->text[i] != NULL) {
          SET_STRING_ELT(col, at, Rf_mkCharCE(cells->text[i], CE_UTF8));
        }
        break;
      case ZU_CELL_BLANK:
        break;
      default:
        REAL(col)[at] = cells->number[i];
        break;
    }
  }

  free(mask);
  free(kind);
  cell_list_finalizer(bag);

  {
    const char *fields[] = {"columns", "header", "is_date", "date1904", ""};
    out = PROTECT(Rf_mkNamed(VECSXP, fields));
    SET_VECTOR_ELT(out, 0, r_cols);
    SET_VECTOR_ELT(out, 1, r_header);
    SET_VECTOR_ELT(out, 2, r_isdate);
    SET_VECTOR_ELT(out, 3, Rf_ScalarLogical(date1904));
    res = PROTECT(result(STATUS_OK, out));
  }
  UNPROTECT(6);
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
