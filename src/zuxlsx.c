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

#include "agile.h"
#include "cfb.h"
#include "encinfo.h"

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
static const char *const STATUS_ENCRYPTED = "format_encrypted";
static const char *const STATUS_XLS = "format_xls";
static const char *const STATUS_XLSB = "format_xlsb";
static const char *const STATUS_XML = "xml_malformed";
static const char *const STATUS_AGILE_PASSWORD = "agile_password";
static const char *const STATUS_AGILE_INTEGRITY = "agile_integrity";
static const char *const STATUS_AGILE_MALFORMED = "agile_malformed";
static const char *const STATUS_AGILE_UNSUPPORTED = "agile_unsupported";
static const char *const STATUS_AGILE_PASSWORD_UTF8 = "agile_password_utf8";
static const char *const STATUS_AGILE_CRYPTO = "agile_crypto";
static const char *const STATUS_CFB_NOT_CFB = "cfb_not_cfb";
static const char *const STATUS_CFB_MALFORMED = "cfb_malformed";
static const char *const STATUS_CFB_NOT_ENCRYPTED = "cfb_not_encrypted";
static const char *const STATUS_ENC_STANDARD = "encryption_standard";
static const char *const STATUS_ENC_EXTENSIBLE = "encryption_extensible";
static const char *const STATUS_ENC_UNKNOWN = "encryption_unknown";
static const char *const STATUS_ENC_CERTIFICATE = "encryption_certificate";

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
 * holds. Which one it is, though, is written in the CFB directory in plain
 * sight: an encrypted package has EncryptionInfo and EncryptedPackage
 * streams, a BIFF workbook has Workbook or Book. Reading far enough to see
 * those names needs the header, the FAT and the directory chain and nothing
 * else -- no mini stream, no stream contents, no password.
 *
 * That is what ole2_kind() below does, and it is the difference between
 * telling someone their file needs a password and telling them it might.
 *
 * Everything in it is bounds-checked and every walk is bounded, because a
 * workbook that arrives encrypted is a workbook somebody else produced. A
 * container can declare a sector past the end of the file, a FAT chain that
 * points at itself, or a name length that runs off the end of its entry; none
 * of those may do anything but end the walk.
 *
 * An .xlsb is a ZIP, and an OPC package, with XML content types and
 * relationships. Only the workbook and worksheet parts differ: BIFF12 binary
 * records rather than XML, so xlsxio finds no part of the content type it
 * wants and the workbook looks empty. Recognising xl/workbook.bin is enough to
 * say so, and costs nothing on the path where a workbook reads normally. */

typedef enum {
  OLE2_NO = 0,        /* not a CFB container at all */
  OLE2_ENCRYPTED,     /* an encrypted OOXML package */
  OLE2_XLS,           /* a legacy BIFF workbook */
  OLE2_UNKNOWN        /* a CFB container holding neither */
} ole2_kind_t;

static uint16_t le16(const unsigned char *p) {
  return (uint16_t) (p[0] | ((uint16_t) p[1] << 8));
}

static uint32_t le32(const unsigned char *p) {
  return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
         ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

#define CFB_ENDOFCHAIN 0xFFFFFFFEu
#define CFB_MAX_DIR_SECTORS 4096   /* a directory this long is pathological */
#define CFB_DIFAT_IN_HEADER 109

/* Reads one sector into buf. Sector n starts at (n + 1) * sector_size,
   because sector numbering begins after the 512-byte header. Returns 0 if
   the sector is not wholly within the file. */
static int cfb_read_sector(FILE *fp, long file_size, uint32_t sector,
                           uint32_t sector_size, unsigned char *buf) {
  /* The multiplication is done in 64-bit and checked, so a sector number
     near 2^32 cannot wrap into a small, valid-looking offset. */
  uint64_t offset = ((uint64_t) sector + 1u) * (uint64_t) sector_size;
  if (offset + sector_size > (uint64_t) file_size) {
    return 0;
  }
  if (fseek(fp, (long) offset, SEEK_SET) != 0) {
    return 0;
  }
  return fread(buf, 1, sector_size, fp) == sector_size;
}

/* Does a directory entry name equal this ASCII string?
 *
 * Names are UTF-16LE and the recorded length counts the terminating null.
 * Comparing against ASCII means every high byte must be zero -- without that
 * check, a name whose characters happen to share low bytes would match. */
static int dir_name_is(const unsigned char *entry, const char *ascii,
                       uint32_t sector_size, size_t entry_offset) {
  uint16_t len = le16(entry + 0x40);
  size_t want = strlen(ascii);
  size_t i;

  /* The length lives inside the entry and is attacker-controlled. */
  if (len < 2 || len > 64 || (len % 2) != 0) {
    return 0;
  }
  if (entry_offset + 128 > sector_size) {
    return 0;
  }
  if ((size_t) (len / 2 - 1) != want) {
    return 0;
  }
  for (i = 0; i < want; i++) {
    if (entry[i * 2] != (unsigned char) ascii[i] || entry[i * 2 + 1] != 0) {
      return 0;
    }
  }
  return 1;
}

static ole2_kind_t ole2_kind(const char *file) {
  static const unsigned char CFB_MAGIC[8] = {
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
  };
  unsigned char header[512];
  unsigned char *sector = NULL;
  unsigned char *fat = NULL;
  FILE *fp;
  long file_size;
  uint32_t sector_size, sector_shift, dir_sector, entries_per_fat;
  uint32_t walked = 0;
  int found_info = 0, found_package = 0, found_biff = 0;
  ole2_kind_t kind = OLE2_NO;

  fp = fopen(file, "rb");
  if (fp == NULL) {
    return OLE2_NO;
  }
  if (fread(header, 1, sizeof(header), fp) != sizeof(header) ||
      memcmp(header, CFB_MAGIC, sizeof(CFB_MAGIC)) != 0) {
    fclose(fp);
    return OLE2_NO;
  }

  /* Past this point the file is a CFB container. Every later failure is a
     container we could not read far enough into, which is still OLE2 --
     reporting it as "not OLE2" would send the caller back to the ZIP error
     it already saw. */
  kind = OLE2_UNKNOWN;

  if (fseek(fp, 0, SEEK_END) != 0) {
    goto done;
  }
  file_size = ftell(fp);
  if (file_size < (long) sizeof(header)) {
    goto done;
  }

  /* Version 3 uses 512-byte sectors and version 4 uses 4096. Reading the
     shift rather than assuming the size is what makes this work on both. */
  sector_shift = le16(header + 0x1E);
  if (sector_shift != 9 && sector_shift != 12) {
    goto done;
  }
  sector_size = 1u << sector_shift;
  entries_per_fat = sector_size / 4u;
  dir_sector = le32(header + 0x30);

  sector = (unsigned char *) malloc(sector_size);
  fat = (unsigned char *) malloc(sector_size);
  if (sector == NULL || fat == NULL) {
    goto done;
  }

  while (dir_sector != CFB_ENDOFCHAIN && walked < CFB_MAX_DIR_SECTORS) {
    uint32_t fat_index, fat_sector, i;

    if (!cfb_read_sector(fp, file_size, dir_sector, sector_size, sector)) {
      break;
    }
    for (i = 0; i + 128 <= sector_size; i += 128) {
      unsigned char *entry = sector + i;
      unsigned char type = entry[0x42];

      if (type != 2 && type != 1 && type != 5) {   /* stream, storage, root */
        continue;
      }
      if (dir_name_is(entry, "EncryptionInfo", sector_size, i)) {
        found_info = 1;
      } else if (dir_name_is(entry, "EncryptedPackage", sector_size, i)) {
        found_package = 1;
      } else if (dir_name_is(entry, "Workbook", sector_size, i) ||
                 dir_name_is(entry, "Book", sector_size, i)) {
        found_biff = 1;
      }
    }

    /* Follow the chain. The FAT entry for a sector lives in the FAT sector
       the header's DIFAT names; only the 109 entries the header carries are
       consulted, which covers every directory chain that is not itself
       enormous, and a file needing more is left as OLE2_UNKNOWN rather than
       chasing DIFAT sectors for a question this small. */
    fat_index = dir_sector / entries_per_fat;
    if (fat_index >= CFB_DIFAT_IN_HEADER) {
      break;
    }
    fat_sector = le32(header + 0x4C + fat_index * 4u);
    if (fat_sector == CFB_ENDOFCHAIN ||
        !cfb_read_sector(fp, file_size, fat_sector, sector_size, fat)) {
      break;
    }
    dir_sector = le32(fat + (dir_sector % entries_per_fat) * 4u);
    walked++;
  }

  /* Both streams, or it is not an encrypted package. EncryptionInfo alone
     appears in containers this reader has no business guessing about. */
  if (found_info && found_package) {
    kind = OLE2_ENCRYPTED;
  } else if (found_biff) {
    kind = OLE2_XLS;
  }

done:
  free(sector);
  free(fat);
  fclose(fp);
  return kind;
}

/* ------------------------------------------------------------------------ */
/* Password-protected workbooks (design section 21c, step 4).
 *
 * A reader is handed either the file or, when the file is an encrypted
 * package and a password was given, the package decrypted into C memory and
 * opened with xlsxioread_open_memory(). The plaintext never becomes an R
 * object and never touches the disk. It belongs to an external pointer whose
 * finalizer wipes it before freeing it, so an error while cells are being
 * built still disposes of it; miniz reads it in place, so it must outlive the
 * reader, which every entry point below closes first. */
typedef struct {
  uint8_t *data;
  size_t len;
} plain_buf;

static void plain_wipe(uint8_t *data, size_t len) {
  if (data != NULL) {
    zuc_secure_zero(data, len);
    free(data);
  }
}

static void plain_buf_finalizer(SEXP ptr) {
  plain_buf *b = (plain_buf *) R_ExternalPtrAddr(ptr);
  if (b == NULL) return;
  plain_wipe(b->data, b->len);
  free(b);
  R_ClearExternalPtr(ptr);
}

static const char *agile_status_string(agile_status st);
static const char *encinfo_status_string(encinfo_status st);

/* The whole file, into C memory. Read in growing chunks rather than sized
   with ftell(), whose long is 32 bits on Windows. */
static int read_file(const char *file, uint8_t **out, size_t *out_len) {
  FILE *fp = fopen(file, "rb");
  uint8_t *buf = NULL;
  size_t len = 0, cap = 0;

  if (fp == NULL) return 0;
  for (;;) {
    size_t got;
    if (len == cap) {
      size_t grown = cap ? cap * 2 : 65536;
      uint8_t *p = (uint8_t *) realloc(buf, grown);
      if (p == NULL || grown < cap) {
        free(buf);
        fclose(fp);
        return -1;
      }
      buf = p;
      cap = grown;
    }
    got = fread(buf + len, 1, cap - len, fp);
    len += got;
    if (got == 0) break;
  }
  fclose(fp);
  *out = buf;
  *out_len = len;
  return 1;
}

/* Steps 1 to 3: a CFB container in memory to the plaintext package, in
   malloc'd memory the caller wipes and frees. No R: the status strings are
   constants. NULL on success. */
static const char *decrypt_package(const uint8_t *bytes, size_t len, const char *pw,
                                   uint8_t **out, size_t *out_len,
                                   zuc_status *crypto) {
  cfb c;
  cfb_status cs;
  encinfo_status es;
  agile_status as;
  encinfo parsed;
  uint8_t *info = NULL, *package = NULL, *plain = NULL;
  size_t info_len = 0, package_len = 0, size = 0;
  const char *status = NULL;

  *out = NULL;
  *out_len = 0;
  *crypto = ZUC_OK;

  cs = cfb_open(&c, bytes, len);
  if (cs == CFB_OK) {
    cs = cfb_stream(&c, "EncryptionInfo", &info, &info_len);
    if (cs == CFB_OK) cs = cfb_stream(&c, "EncryptedPackage", &package, &package_len);
    cfb_close(&c);
  }
  switch (cs) {
  case CFB_OK: break;
  case CFB_NOT_CFB: status = STATUS_CFB_NOT_CFB; break;
  case CFB_NOT_FOUND: status = STATUS_CFB_NOT_ENCRYPTED; break;
  case CFB_MEMORY: status = STATUS_MEMORY; break;
  default: status = STATUS_CFB_MALFORMED; break;
  }
  if (status != NULL) goto done;

  es = encinfo_parse(info, info_len, &parsed);
  if (es != ENCINFO_OK) {
    status = encinfo_status_string(es);
    goto done;
  }
  as = agile_package_size(package, package_len, &size);
  if (as == AGILE_OK) {
    plain = (uint8_t *) malloc(size > 0 ? size : 1);
    if (plain == NULL) as = AGILE_MEMORY;
  }
  if (as == AGILE_OK) {
    as = agile_decrypt(&parsed.params, pw, strlen(pw), package, package_len,
                       plain, size, crypto);
  }
  encinfo_free(&parsed);
  if (as != AGILE_OK) {
    plain_wipe(plain, size);
    plain = NULL;
    status = agile_status_string(as);
  }

done:
  free(info);
  free(package);
  if (status == NULL) {
    *out = plain;
    *out_len = size;
  }
  return status;
}

/* What a reader should open. For anything but an OLE2 container, the file,
   and *plain stays NULL. For an encrypted package with a password, its
   plaintext, owned by `holder`. Otherwise the status to report -- with a
   detail in *detail for a cryptographic backend failure, which the caller
   must protect.

   Called before any reader is open: it allocates R memory when it fails. */
static const char *resolve_source(const char *file, SEXP password, SEXP holder,
                                  SEXP *detail) {
  plain_buf *b = (plain_buf *) R_ExternalPtrAddr(holder);
  ole2_kind_t kind = ole2_kind(file);
  uint8_t *bytes = NULL;
  size_t len = 0;
  zuc_status crypto = ZUC_OK;
  const char *status;
  int rc;

  *detail = R_NilValue;
  if (kind == OLE2_NO) return NULL;
  /* A password changes nothing for a legacy .xls or an unknown container,
     and without one an encrypted package is still only reported. */
  if (kind != OLE2_ENCRYPTED || password == R_NilValue) {
    return kind == OLE2_ENCRYPTED ? STATUS_ENCRYPTED
         : kind == OLE2_XLS ? STATUS_XLS : STATUS_OLE2;
  }

  rc = read_file(file, &bytes, &len);
  if (rc <= 0) return rc < 0 ? STATUS_MEMORY : STATUS_ZIP_OPEN;
  status = decrypt_package(bytes, len, CHAR(STRING_ELT(password, 0)),
                           &b->data, &b->len, &crypto);
  free(bytes);
  if (status == STATUS_AGILE_CRYPTO) {
    *detail = Rf_mkString(zuc_status_name(crypto));
  }
  return status;
}

static SEXP make_plain_holder(void) {
  plain_buf *b = (plain_buf *) calloc(1, sizeof *b);
  SEXP holder;
  if (b == NULL) return R_NilValue;
  holder = PROTECT(R_MakeExternalPtr(b, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(holder, plain_buf_finalizer, TRUE);
  UNPROTECT(1);
  return holder;
}

static xlsxioreader open_reader(const char *file, const plain_buf *b) {
  return b->data != NULL
    ? xlsxioread_open_memory(b->data, (uint64_t) b->len, 0)
    : xlsxioread_open(file);
}

/* The password argument as the entry points take it: NULL, or one string R
   has already made UTF-8 and checked. */
static int password_ok(SEXP password) {
  return password == R_NilValue ||
         (TYPEOF(password) == STRSXP && XLENGTH(password) == 1 &&
          STRING_ELT(password, 0) != NA_STRING);
}

/* Only asked once a workbook has already failed to declare a worksheet, so
   the second open costs nothing in the normal case. */
/* Opens the archive a reader would: the file, or the decrypted package in
   memory when there is one. */
static int zip_open(mz_zip_archive *zip, const char *file,
                    const uint8_t *buf, size_t len) {
  memset(zip, 0, sizeof(*zip));
  return buf != NULL ? mz_zip_reader_init_mem(zip, buf, len, 0)
                     : mz_zip_reader_init_file(zip, file, 0);
}

static int file_is_xlsb(const char *file, const uint8_t *buf, size_t len) {
  mz_zip_archive zip;
  mz_uint32 index;
  int found = 0;

  if (!zip_open(&zip, file, buf, len)) {
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
static int first_malformed_part(const char *file, const uint8_t *zbuf,
                                size_t zlen, char *out, size_t outlen,
                                int *line) {
  static const char *const PARTS[] = {"[Content_Types].xml", "xl/workbook.xml"};
  mz_zip_archive zip;
  size_t i;
  int found = 0;

  if (!zip_open(&zip, file, zbuf, zlen)) {
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

SEXP C_xlsx_sheets(SEXP path, SEXP password) {
  const char *file;
  const char *status;
  sheet_list *sheets;
  plain_buf *plain;
  xlsxioreader reader;
  SEXP bag, holder, detail, out, res;
  size_t i;

  /* R validates the argument before calling, but the registered symbol is
     reachable from the namespace, so a wrong type must not be a crash. */
  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING || !password_ok(password)) {
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
  holder = PROTECT(make_plain_holder());
  if (holder == R_NilValue) {
    sheet_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }

  /* An OLE2 container will not open as a ZIP, so this has to be asked before
     the reader is handed the path or the answer is "corrupt archive". With a
     password, an encrypted one is decrypted here instead. */
  status = resolve_source(file, password, holder, &detail);
  if (status != NULL) {
    PROTECT(detail);
    sheet_list_finalizer(bag);
    plain_buf_finalizer(holder);
    res = result(status, detail);
    UNPROTECT(3);
    return res;
  }
  plain = (plain_buf *) R_ExternalPtrAddr(holder);

  /* No R allocation between here and xlsxioread_close(): while the reader is
     open it owns a miniz archive handle and an Expat parser, and neither is
     reachable from R to be cleaned up if something unwound past them. */
  reader = open_reader(file, plain);
  if (reader == NULL) {
    sheet_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  xlsxioread_list_sheets(reader, collect_sheet, sheets);
  xlsxioread_close(reader);

  if (sheets->oom) {
    sheet_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }
  /* A workbook has at least one worksheet: CT_Sheets requires 1..n. Zero here
     means the ZIP opened but is not a workbook -- no [Content_Types].xml, no
     workbook part, or a workbook with no <sheet> elements. Reporting that as
     an empty character vector would make a wrong file look like an odd one. */
  if (sheets->n == 0) {
    char part[64];
    int line = 0;
    int xlsb = file_is_xlsb(file, plain->data, plain->len);
    const char *why = STATUS_NO_SHEETS;

    if (xlsb) {
      why = STATUS_XLSB;
    } else if (first_malformed_part(file, plain->data, plain->len,
                                    part, sizeof(part), &line)) {
      why = STATUS_XML;
    }
    sheet_list_finalizer(bag);
    plain_buf_finalizer(holder);
    if (why == STATUS_XML) {
      const char *fields[] = {"part", "line", ""};
      detail = PROTECT(Rf_mkNamed(VECSXP, fields));
      SET_VECTOR_ELT(detail, 0, Rf_mkString(part));
      SET_VECTOR_ELT(detail, 1, Rf_ScalarInteger(line));
      res = PROTECT(result(why, detail));
      UNPROTECT(4);
      return res;
    }
    UNPROTECT(2);
    return result(why, R_NilValue);
  }
  plain_buf_finalizer(holder);

  out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)sheets->n));
  for (i = 0; i < sheets->n; i++) {
    SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(sheets->names[i], CE_UTF8));
  }
  sheet_list_finalizer(bag);

  /* result() allocates, so out stays protected across it. */
  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(4);
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
  /* A decrypted package the reader reads in place, or NULL. Held here rather
     than in its own external pointer so that one finalizer closes the reader
     before the buffer is wiped: two finalizers run in no guaranteed order. */
  plain_buf plain;
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
    plain_wipe(h->plain.data, h->plain.len);
    free(h);
    R_ClearExternalPtr(ptr);
  }
}

SEXP C_xlsx_cells(SEXP path, SEXP sheet, SEXP password) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  xlsxioreader reader;
  xlsxioreadersheet worksheet;
  plain_buf *plain;
  const char *status;
  SEXP bag, holder, detail, out, res;
  size_t i;
  size_t rownr = 0;
  int date1904 = 0;

  if (TYPEOF(path) != STRSXP || XLENGTH(path) < 1 ||
      STRING_ELT(path, 0) == NA_STRING ||
      TYPEOF(sheet) != STRSXP || XLENGTH(sheet) < 1 ||
      STRING_ELT(sheet, 0) == NA_STRING || !password_ok(password)) {
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
  holder = PROTECT(make_plain_holder());
  if (holder == R_NilValue) {
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }

  status = resolve_source(file, password, holder, &detail);
  if (status != NULL) {
    PROTECT(detail);
    cell_list_finalizer(bag);
    plain_buf_finalizer(holder);
    res = result(status, detail);
    UNPROTECT(3);
    return res;
  }
  plain = (plain_buf *) R_ExternalPtrAddr(holder);

  /* No R allocation until xlsxioread_close(). */
  reader = open_reader(file, plain);
  if (reader == NULL) {
    cell_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  worksheet = xlsxioread_sheet_open(reader, sheetname, XLSXIOREAD_SKIP_NONE);
  if (worksheet == NULL) {
    xlsxioread_close(reader);
    cell_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
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
  plain_buf_finalizer(holder);

  if (cells->oom) {
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }

  out = PROTECT(cells_to_list(cells, date1904));
  cell_list_finalizer(bag);

  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(4);
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
                       SEXP chunk, SEXP password) {
  const char *file;
  const char *sheetname;
  const char *status;
  cell_list *cells;
  reader_handle *handle;
  plain_buf *plain;
  SEXP bag, holder, source, detail, res;
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
      INTEGER(chunk)[0] == NA_INTEGER || INTEGER(chunk)[0] < 1 ||
      !password_ok(password)) {
    return result(STATUS_BAD_PATH, R_NilValue);
  }
  file = Rf_translateCharUTF8(STRING_ELT(path, 0));
  sheetname = Rf_translateCharUTF8(STRING_ELT(sheet, 0));
  limit = (size_t)INTEGER(chunk)[0];

  source = PROTECT(make_plain_holder());
  if (source == R_NilValue) {
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  status = resolve_source(file, password, source, &detail);
  if (status != NULL) {
    PROTECT(detail);
    plain_buf_finalizer(source);
    res = result(status, detail);
    UNPROTECT(2);
    return res;
  }
  plain = (plain_buf *) R_ExternalPtrAddr(source);

  cells = (cell_list *)calloc(1, sizeof(cell_list));
  if (cells == NULL) {
    plain_buf_finalizer(source);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(cells, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, cell_list_finalizer, TRUE);

  handle = (reader_handle *)calloc(1, sizeof(reader_handle));
  if (handle == NULL) {
    cell_list_finalizer(bag);
    plain_buf_finalizer(source);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }
  holder = PROTECT(R_MakeExternalPtr(handle, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(holder, reader_handle_finalizer, TRUE);

  /* The plaintext moves into the handle, which from here on owns it. Nothing
     between the finalizer registration above and this can longjmp. */
  handle->plain = *plain;
  plain->data = NULL;
  plain->len = 0;

  handle->reader = open_reader(file, &handle->plain);
  if (handle->reader == NULL) {
    reader_handle_finalizer(holder);
    cell_list_finalizer(bag);
    UNPROTECT(3);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  handle->sheet = xlsxioread_sheet_open(handle->reader, sheetname,
                                        XLSXIOREAD_SKIP_NONE);
  if (handle->sheet == NULL) {
    reader_handle_finalizer(holder);
    cell_list_finalizer(bag);
    UNPROTECT(3);
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
    UNPROTECT(3);
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
  UNPROTECT(4);
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

SEXP C_read_xlsx(SEXP path, SEXP sheet, SEXP col_names, SEXP bounds,
                 SEXP password) {
  const char *file;
  const char *sheetname;
  cell_list *cells;
  xlsxioreader reader;
  xlsxioreadersheet worksheet;
  plain_buf *plain;
  const char *status;
  SEXP bag, holder, detail, out, res, r_cols, r_header, r_isdate;
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
      TYPEOF(col_names) != LGLSXP || XLENGTH(col_names) < 1 ||
      !password_ok(password)) {
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

  holder = PROTECT(make_plain_holder());
  if (holder == R_NilValue) {
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  status = resolve_source(file, password, holder, &detail);
  if (status != NULL) {
    PROTECT(detail);
    plain_buf_finalizer(holder);
    res = result(status, detail);
    UNPROTECT(2);
    return res;
  }
  plain = (plain_buf *) R_ExternalPtrAddr(holder);

  cells = (cell_list *)calloc(1, sizeof(cell_list));
  if (cells == NULL) {
    plain_buf_finalizer(holder);
    UNPROTECT(1);
    return result(STATUS_MEMORY, R_NilValue);
  }
  bag = PROTECT(R_MakeExternalPtr(cells, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, cell_list_finalizer, TRUE);

  /* No R allocation until xlsxioread_close(). */
  reader = open_reader(file, plain);
  if (reader == NULL) {
    cell_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
    return result(STATUS_ZIP_OPEN, R_NilValue);
  }
  worksheet = xlsxioread_sheet_open(reader, sheetname, XLSXIOREAD_SKIP_NONE);
  if (worksheet == NULL) {
    xlsxioread_close(reader);
    cell_list_finalizer(bag);
    plain_buf_finalizer(holder);
    UNPROTECT(2);
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
  plain_buf_finalizer(holder);

  if (cells->oom) {
    cell_list_finalizer(bag);
    UNPROTECT(2);
    return result(STATUS_MEMORY, R_NilValue);
  }
  if (cells->n == 0) {
    cell_list_finalizer(bag);
    UNPROTECT(2);
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
    UNPROTECT(2);
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
  UNPROTECT(7);
  return res;
}

SEXP C_zuxlsx_native(void) {
  const char *fields[] = {"xlsxio", "expat", "miniz", "tf_psa_crypto", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SEXP res;
  zuc_info info;

  SET_VECTOR_ELT(out, 0, Rf_mkString(XLSXIO_VERSION_STRING));
  /* A real call into libzuxml.a, not a macro: a header that is on the path
     while the archive is not would still compile, and this is what makes
     that fail at link time instead. */
  SET_VECTOR_ELT(out, 1, Rf_mkString(XML_ExpatVersion()));
  SET_VECTOR_ELT(out, 2, Rf_mkString(MZ_VERSION));
  /* The same for libzucrypt.a: zucrypt.h carries no backend version at all,
     so this can only come from the archive. NA if zuc_init() failed when the
     DLL loaded, which is then also what every decryption reports. */
  memset(&info, 0, sizeof info);
  info.struct_size = (uint32_t) sizeof info;
  SET_VECTOR_ELT(out, 3, zuc_get_info(&info) == ZUC_OK
                 ? Rf_mkString(info.backend_version)
                 : Rf_ScalarString(NA_STRING));

  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(2);
  return res;
}

/* Agile decryption, with the EncryptionInfo parameters supplied from R (design
   section 21c, step 3). The parameters are a named list mirroring
   agile_params; anything missing, mistyped or out of range reaches the core as
   a value it refuses, so a malformed EncryptionInfo is reported the same way
   whether R or, later, the C parser read it.

   The plaintext buffer is allocated before the core runs, which is what keeps
   R's allocator -- and its longjmp -- away from the zucrypt handles and the
   key material the core holds. The size it is allocated at is bounded by the
   ciphertext actually present, never by the length the file declares. */

static SEXP list_elt(SEXP list, const char *name) {
  SEXP names = Rf_getAttrib(list, R_NamesSymbol);
  R_xlen_t i;

  if (TYPEOF(list) != VECSXP || TYPEOF(names) != STRSXP) return R_NilValue;
  for (i = 0; i < XLENGTH(list); i++) {
    if (strcmp(CHAR(STRING_ELT(names, i)), name) == 0) return VECTOR_ELT(list, i);
  }
  return R_NilValue;
}

static const char *param_string(SEXP list, const char *name) {
  SEXP x = list_elt(list, name);
  if (TYPEOF(x) != STRSXP || XLENGTH(x) != 1 || STRING_ELT(x, 0) == NA_STRING) {
    return NULL;
  }
  return CHAR(STRING_ELT(x, 0));
}

/* -1 for anything that is not a whole number in range, which every check in
   the core refuses. */
static long param_long(SEXP list, const char *name) {
  SEXP x = list_elt(list, name);
  double v;

  if (TYPEOF(x) == INTSXP && XLENGTH(x) == 1) {
    return INTEGER(x)[0] == NA_INTEGER ? -1 : (long) INTEGER(x)[0];
  }
  if (TYPEOF(x) != REALSXP || XLENGTH(x) != 1) return -1;
  v = REAL(x)[0];
  if (!R_FINITE(v) || v < 0 || v > 2147483647.0 || v != (double) (long) v) return -1;
  return (long) v;
}

static const uint8_t *param_raw(SEXP list, const char *name, size_t *len) {
  SEXP x = list_elt(list, name);
  if (TYPEOF(x) != RAWSXP) {
    *len = 0;
    return NULL;
  }
  *len = (size_t) XLENGTH(x);
  return RAW(x);
}

static void param_cipher(SEXP list, agile_cipher *out) {
  out->cipher_algorithm = param_string(list, "cipher_algorithm");
  out->cipher_chaining = param_string(list, "cipher_chaining");
  out->hash_algorithm = param_string(list, "hash_algorithm");
  out->salt_size = param_long(list, "salt_size");
  out->block_size = param_long(list, "block_size");
  out->key_bits = param_long(list, "key_bits");
  out->hash_size = param_long(list, "hash_size");
  out->salt = param_raw(list, "salt", &out->salt_len);
}

static const char *agile_status_string(agile_status st) {
  switch (st) {
  case AGILE_OK: return STATUS_OK;
  case AGILE_WRONG_PASSWORD: return STATUS_AGILE_PASSWORD;
  case AGILE_INTEGRITY: return STATUS_AGILE_INTEGRITY;
  case AGILE_MALFORMED: return STATUS_AGILE_MALFORMED;
  case AGILE_UNSUPPORTED: return STATUS_AGILE_UNSUPPORTED;
  case AGILE_BAD_PASSWORD: return STATUS_AGILE_PASSWORD_UTF8;
  case AGILE_MEMORY: return STATUS_MEMORY;
  case AGILE_CRYPTO: return STATUS_AGILE_CRYPTO;
  }
  return STATUS_AGILE_CRYPTO;
}

SEXP C_agile_decrypt(SEXP params, SEXP password, SEXP package) {
  agile_params p;
  agile_status st;
  zuc_status crypto = ZUC_OK;
  size_t size = 0;
  const char *pw;
  SEXP out;

  if (TYPEOF(package) != RAWSXP || TYPEOF(params) != VECSXP) {
    return result(STATUS_AGILE_MALFORMED, NULL);
  }
  /* R has already made this UTF-8 and checked it is valid; the core checks
     again, since it is the layer that encodes it. */
  if (TYPEOF(password) != STRSXP || XLENGTH(password) != 1 ||
      STRING_ELT(password, 0) == NA_STRING) {
    return result(STATUS_AGILE_PASSWORD_UTF8, NULL);
  }
  pw = CHAR(STRING_ELT(password, 0));

  memset(&p, 0, sizeof p);
  param_cipher(list_elt(params, "key_data"), &p.key_data);
  p.encrypted_hmac_key =
    param_raw(params, "encrypted_hmac_key", &p.encrypted_hmac_key_len);
  p.encrypted_hmac_value =
    param_raw(params, "encrypted_hmac_value", &p.encrypted_hmac_value_len);
  param_cipher(list_elt(params, "password"), &p.password);
  p.spin_count = param_long(list_elt(params, "password"), "spin_count");
  p.encrypted_verifier_hash_input =
    param_raw(list_elt(params, "password"), "encrypted_verifier_hash_input",
              &p.encrypted_verifier_hash_input_len);
  p.encrypted_verifier_hash_value =
    param_raw(list_elt(params, "password"), "encrypted_verifier_hash_value",
              &p.encrypted_verifier_hash_value_len);
  p.encrypted_key_value =
    param_raw(list_elt(params, "password"), "encrypted_key_value",
              &p.encrypted_key_value_len);

  st = agile_package_size(RAW(package), (size_t) XLENGTH(package), &size);
  if (st != AGILE_OK) return result(agile_status_string(st), NULL);

  out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t) size));
  st = agile_decrypt(&p, pw, strlen(pw), RAW(package), (size_t) XLENGTH(package),
                     RAW(out), size, &crypto);
  if (st != AGILE_OK) {
    /* The zucrypt status by name, never by number (zucrypt.h). */
    SEXP why = PROTECT(st == AGILE_CRYPTO
                       ? Rf_mkString(zuc_status_name(crypto)) : R_NilValue);
    SEXP res = PROTECT(result(agile_status_string(st), why));
    UNPROTECT(3);
    return res;
  }
  out = PROTECT(result(STATUS_OK, out));
  UNPROTECT(2);
  return out;
}

/* Streams at the root of a CFB container held in memory (design section
   21c, step 1). One raw vector per name, or NULL where there is no such
   stream; a container too damaged to read is a status, not a partial list.

   The streams are read into C memory while the container is open, and no R
   allocation happens until cfb_close(). The buffers themselves then outlive
   that, while each is copied into R, so they belong to an external pointer
   whose finalizer frees them: an allocation failure part way through the
   copy unwinds past this function, and the finalizer is what still runs. */
typedef struct {
  uint8_t **data;
  size_t *lens;
  size_t n;
} stream_bufs;

static void stream_bufs_finalizer(SEXP ptr) {
  stream_bufs *b = (stream_bufs *) R_ExternalPtrAddr(ptr);
  size_t i;

  if (b == NULL) return;
  for (i = 0; i < b->n; i++) free(b->data[i]);
  free(b->data);
  free(b->lens);
  free(b);
  R_ClearExternalPtr(ptr);
}

SEXP C_cfb_streams(SEXP bytes, SEXP names) {
  cfb c;
  cfb_status st;
  R_xlen_t i, n;
  stream_bufs *b;
  const char *status = NULL;
  SEXP bag, out, res;

  if (TYPEOF(bytes) != RAWSXP || TYPEOF(names) != STRSXP) {
    return result(STATUS_CFB_MALFORMED, NULL);
  }
  n = XLENGTH(names);

  b = (stream_bufs *) calloc(1, sizeof *b);
  bag = PROTECT(R_MakeExternalPtr(b, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, stream_bufs_finalizer, TRUE);
  if (b == NULL) {
    UNPROTECT(1);
    return result(STATUS_MEMORY, NULL);
  }
  b->data = (uint8_t **) calloc((size_t) n + 1, sizeof *b->data);
  b->lens = (size_t *) calloc((size_t) n + 1, sizeof *b->lens);
  if (b->data == NULL || b->lens == NULL) {
    stream_bufs_finalizer(bag);
    UNPROTECT(1);
    return result(STATUS_MEMORY, NULL);
  }
  b->n = (size_t) n;

  /* No R allocation between cfb_open() and cfb_close(). */
  st = cfb_open(&c, RAW(bytes), (size_t) XLENGTH(bytes));
  if (st == CFB_OK) {
    for (i = 0; i < n && status == NULL; i++) {
      cfb_status s;
      if (STRING_ELT(names, i) == NA_STRING) continue;
      s = cfb_stream(&c, CHAR(STRING_ELT(names, i)), &b->data[i], &b->lens[i]);
      if (s == CFB_MEMORY) {
        status = STATUS_MEMORY;
      } else if (s != CFB_OK && s != CFB_NOT_FOUND) {
        status = STATUS_CFB_MALFORMED;
      }
    }
    cfb_close(&c);
  } else {
    status = st == CFB_NOT_CFB ? STATUS_CFB_NOT_CFB
           : st == CFB_MEMORY ? STATUS_MEMORY : STATUS_CFB_MALFORMED;
  }
  if (status != NULL) {
    stream_bufs_finalizer(bag);
    UNPROTECT(1);
    return result(status, NULL);
  }

  /* A stream that was found has a non-NULL buffer even when it is empty. */
  out = PROTECT(Rf_allocVector(VECSXP, n));
  for (i = 0; i < n; i++) {
    if (b->data[i] != NULL) {
      SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t) b->lens[i]);
      if (b->lens[i] > 0) memcpy(RAW(raw), b->data[i], b->lens[i]);
      SET_VECTOR_ELT(out, i, raw);
    }
  }
  Rf_setAttrib(out, R_NamesSymbol, names);
  stream_bufs_finalizer(bag);
  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(3);
  return res;
}

/* EncryptionInfo, parsed in C (design section 21c, step 2), and the whole
   chain from a container in memory to the plaintext package: steps 1, 2 and
   3 together.

   Both hold C memory -- the two streams, the parsed parameters -- across R
   allocations, so it belongs to an external pointer whose finalizer frees
   it, the same way C_cfb_streams() holds its buffers. */
typedef struct {
  uint8_t *info;
  size_t info_len;
  uint8_t *package;
  size_t package_len;
  encinfo parsed;
  int have_parsed;
} decrypt_bag;

static void decrypt_bag_finalizer(SEXP ptr) {
  decrypt_bag *b = (decrypt_bag *) R_ExternalPtrAddr(ptr);
  if (b == NULL) return;
  free(b->info);
  free(b->package);
  if (b->have_parsed) encinfo_free(&b->parsed);
  free(b);
  R_ClearExternalPtr(ptr);
}

static const char *encinfo_status_string(encinfo_status st) {
  switch (st) {
  case ENCINFO_OK: return STATUS_OK;
  case ENCINFO_STANDARD: return STATUS_ENC_STANDARD;
  case ENCINFO_EXTENSIBLE: return STATUS_ENC_EXTENSIBLE;
  case ENCINFO_UNKNOWN: return STATUS_ENC_UNKNOWN;
  case ENCINFO_NO_PASSWORD: return STATUS_ENC_CERTIFICATE;
  case ENCINFO_MALFORMED: return STATUS_AGILE_MALFORMED;
  case ENCINFO_MEMORY: return STATUS_MEMORY;
  }
  return STATUS_AGILE_MALFORMED;
}

static SEXP make_decrypt_bag(decrypt_bag **out) {
  decrypt_bag *b = (decrypt_bag *) calloc(1, sizeof *b);
  SEXP bag = PROTECT(R_MakeExternalPtr(b, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(bag, decrypt_bag_finalizer, TRUE);
  UNPROTECT(1);
  *out = b;
  return bag;
}

/* The parameters as the R list agile_decrypt() takes, which is also what
   helper-ole2.R's parser builds -- so the tests can compare the two. */
static SEXP raw_or_null(const uint8_t *p, size_t len) {
  SEXP out;
  if (p == NULL) return R_NilValue;
  out = Rf_allocVector(RAWSXP, (R_xlen_t) len);
  if (len > 0) memcpy(RAW(out), p, len);
  return out;
}

static SEXP str_or_null(const char *s) {
  return s == NULL ? R_NilValue : Rf_mkString(s);
}

static SEXP num_or_na(long v) {
  return Rf_ScalarReal(v < 0 ? NA_REAL : (double) v);
}

static SEXP cipher_list(const agile_cipher *c, const agile_params *pw) {
  const char *fields[] = {"cipher_algorithm", "cipher_chaining", "hash_algorithm",
                          "salt_size", "block_size", "key_bits", "hash_size",
                          "salt", "spin_count", "encrypted_verifier_hash_input",
                          "encrypted_verifier_hash_value", "encrypted_key_value", ""};
  SEXP out;
  if (pw == NULL) fields[8] = "";
  out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SET_VECTOR_ELT(out, 0, str_or_null(c->cipher_algorithm));
  SET_VECTOR_ELT(out, 1, str_or_null(c->cipher_chaining));
  SET_VECTOR_ELT(out, 2, str_or_null(c->hash_algorithm));
  SET_VECTOR_ELT(out, 3, num_or_na(c->salt_size));
  SET_VECTOR_ELT(out, 4, num_or_na(c->block_size));
  SET_VECTOR_ELT(out, 5, num_or_na(c->key_bits));
  SET_VECTOR_ELT(out, 6, num_or_na(c->hash_size));
  SET_VECTOR_ELT(out, 7, raw_or_null(c->salt, c->salt_len));
  if (pw != NULL) {
    SET_VECTOR_ELT(out, 8, num_or_na(pw->spin_count));
    SET_VECTOR_ELT(out, 9, raw_or_null(pw->encrypted_verifier_hash_input,
                                       pw->encrypted_verifier_hash_input_len));
    SET_VECTOR_ELT(out, 10, raw_or_null(pw->encrypted_verifier_hash_value,
                                        pw->encrypted_verifier_hash_value_len));
    SET_VECTOR_ELT(out, 11, raw_or_null(pw->encrypted_key_value,
                                        pw->encrypted_key_value_len));
  }
  UNPROTECT(1);
  return out;
}

SEXP C_encryption_info(SEXP stream) {
  const char *fields[] = {"key_data", "encrypted_hmac_key", "encrypted_hmac_value",
                          "password", ""};
  decrypt_bag *b;
  SEXP bag, out, res;
  encinfo_status st;
  const agile_params *p;

  if (TYPEOF(stream) != RAWSXP) return result(STATUS_AGILE_MALFORMED, NULL);
  bag = PROTECT(make_decrypt_bag(&b));
  if (b == NULL) {
    UNPROTECT(1);
    return result(STATUS_MEMORY, NULL);
  }
  st = encinfo_parse(RAW(stream), (size_t) XLENGTH(stream), &b->parsed);
  if (st != ENCINFO_OK) {
    UNPROTECT(1);
    return result(encinfo_status_string(st), NULL);
  }
  b->have_parsed = 1;
  p = &b->parsed.params;

  out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SET_VECTOR_ELT(out, 0, cipher_list(&p->key_data, NULL));
  SET_VECTOR_ELT(out, 1, raw_or_null(p->encrypted_hmac_key, p->encrypted_hmac_key_len));
  SET_VECTOR_ELT(out, 2, raw_or_null(p->encrypted_hmac_value, p->encrypted_hmac_value_len));
  SET_VECTOR_ELT(out, 3, cipher_list(&p->password, p));
  decrypt_bag_finalizer(bag);
  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(3);
  return res;
}

SEXP C_decrypt_ole2(SEXP bytes, SEXP password) {
  SEXP holder, out, res;
  plain_buf *b;
  zuc_status crypto = ZUC_OK;
  const char *status;

  if (TYPEOF(bytes) != RAWSXP) return result(STATUS_CFB_MALFORMED, NULL);
  if (TYPEOF(password) != STRSXP || XLENGTH(password) != 1 ||
      STRING_ELT(password, 0) == NA_STRING) {
    return result(STATUS_AGILE_PASSWORD_UTF8, NULL);
  }
  holder = PROTECT(make_plain_holder());
  if (holder == R_NilValue) {
    UNPROTECT(1);
    return result(STATUS_MEMORY, NULL);
  }
  b = (plain_buf *) R_ExternalPtrAddr(holder);

  status = decrypt_package(RAW(bytes), (size_t) XLENGTH(bytes),
                           CHAR(STRING_ELT(password, 0)), &b->data, &b->len, &crypto);
  if (status != NULL) {
    SEXP why = PROTECT(status == STATUS_AGILE_CRYPTO
                       ? Rf_mkString(zuc_status_name(crypto)) : R_NilValue);
    res = PROTECT(result(status, why));
    UNPROTECT(3);
    return res;
  }

  /* A copy into R, for the tests: the readers never make one. */
  out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t) b->len));
  if (b->len > 0) memcpy(RAW(out), b->data, b->len);
  plain_buf_finalizer(holder);
  res = PROTECT(result(STATUS_OK, out));
  UNPROTECT(3);
  return res;
}
