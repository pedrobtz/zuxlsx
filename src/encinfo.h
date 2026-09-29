/* Parsing the EncryptionInfo stream ([MS-OFFCRYPTO] 2.3.4.10) into the
 * parameters agile_decrypt() takes. Design section 21c, step 2.
 *
 * Eight bytes of version and flags, then -- for agile encryption only -- an
 * XML descriptor, parsed here with Expat. The version is checked first, and
 * anything that is not agile is refused by the name of what it is: deriving
 * a key with the wrong scheme and reporting a wrong password is the failure
 * design section 21c exists to prevent.
 *
 * Plain C, no R, like cfb.c and agile.c. Nothing here decides whether a
 * parameter is acceptable beyond parsing it: agile_decrypt() checks every
 * value, so a missing attribute is a NULL or a -1 here and malformed there.
 */
#ifndef ZUXLSX_ENCINFO_H
#define ZUXLSX_ENCINFO_H

#include <stddef.h>
#include <stdint.h>

#include "agile.h"

typedef enum {
  ENCINFO_OK = 0,
  ENCINFO_STANDARD,      /* version 2.2, 3.2 or 4.2: Office 2007's scheme */
  ENCINFO_EXTENSIBLE,    /* version 3.3 or 4.3: a third-party provider */
  ENCINFO_UNKNOWN,       /* a version [MS-OFFCRYPTO] does not define */
  ENCINFO_NO_PASSWORD,   /* agile, but no password key encryptor */
  ENCINFO_MALFORMED,     /* not well-formed XML, not the descriptor, or a DTD */
  ENCINFO_MEMORY
} encinfo_status;

/* agile_params plus the storage its pointers point into. */
typedef struct {
  agile_params params;
  char *strings[6];
  uint8_t *blobs[7];
} encinfo;

/* On ENCINFO_OK, `info` owns everything its params point at and must be
 * released with encinfo_free(). On any other status there is nothing to
 * free. */
encinfo_status encinfo_parse(const uint8_t *stream, size_t len, encinfo *info);

void encinfo_free(encinfo *info);

#endif
