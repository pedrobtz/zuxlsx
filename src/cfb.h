/* Reading stream contents out of a Compound File Binary container
 * ([MS-CFB]), over a buffer in memory. Design section 21c, step 1.
 *
 * An encrypted workbook is a CFB container holding two streams,
 * EncryptionInfo and EncryptedPackage. ole2_kind() in zuxlsx.c reads only
 * the directory names, to say which kind of container a file is; this reads
 * what the streams contain, which needs the FAT, the miniFAT and the mini
 * stream as well.
 *
 * Plain C, no R, like agile.c, so tools/fuzz can drive it (#45). Every input
 * is hostile: a sector number is checked against the buffer before it is
 * used, sector offsets are computed in 64 bits, every chain walk is bounded
 * by the number of sectors the buffer holds, the directory tree walk visits
 * each entry at most once, and a stream's declared size must be backed by
 * its chain before a byte of it is copied.
 */
#ifndef ZUXLSX_CFB_H
#define ZUXLSX_CFB_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
  CFB_OK = 0,
  CFB_NOT_CFB,     /* no CFB signature: not a container at all */
  CFB_MALFORMED,   /* a container, but inconsistent where it matters */
  CFB_NOT_FOUND,   /* no stream of that name at the root */
  CFB_MEMORY
} cfb_status;

typedef struct {
  const uint8_t *buf;
  size_t len;
  uint32_t sector_size;
  uint32_t mini_sector_size;
  uint32_t mini_cutoff;
  int version;              /* 3 or 4 */
  uint64_t n_sectors;       /* whole sectors the buffer holds after the header */

  uint32_t *fat_sectors;    /* the DIFAT: which sectors hold the FAT */
  size_t n_fat_sectors;
  uint32_t *dir_sectors;    /* the directory's chain */
  size_t n_dir_sectors;
  uint32_t *minifat_sectors;
  size_t n_minifat_sectors;
  uint32_t *mini_sectors;   /* the mini stream's chain, from the root entry */
  size_t n_mini_sectors;
  uint64_t mini_size;       /* the root entry's size: the mini stream's length */
} cfb;

/* Checks the header and reads the DIFAT, the directory chain, the miniFAT
 * chain and the mini stream's chain. `buf` must outlive the cfb; nothing is
 * copied out of it here. On any status but CFB_OK there is nothing to close. */
cfb_status cfb_open(cfb *c, const uint8_t *buf, size_t len);

void cfb_close(cfb *c);

/* A stream directly under the root storage, by ASCII name, compared the way
 * [MS-CFB] 2.6.4 compares names (case-insensitively). On CFB_OK, *out is
 * malloc'd and holds exactly *out_len bytes -- the entry's declared size --
 * and the caller frees it. A zero-length stream is CFB_OK with *out_len 0
 * and a non-NULL *out. */
cfb_status cfb_stream(const cfb *c, const char *name,
                      uint8_t **out, size_t *out_len);

#endif
