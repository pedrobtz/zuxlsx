/* Compound File Binary stream reading. See cfb.h for the contract.
 *
 * References are to [MS-CFB] v20240423:
 *   2.2  the header
 *   2.3  sector numbers and the special values above MAXREGSECT
 *   2.5  the DIFAT, and the DIFAT sectors past the header's 109 entries
 *   2.4  the FAT; 2.6.x the directory; 2.3 again for the miniFAT and the
 *        mini stream, which lives in the root entry's chain
 *
 * Two things are deliberately stricter than some readers. A sector the buffer
 * does not wholly contain is unreadable: a truncated last sector is not
 * padded, so a stream that needs it is malformed. And a stream name that
 * appears twice at the root is malformed, since [MS-CFB] forbids it and
 * choosing one would be a guess about which the producer meant.
 */
#include "cfb.h"

#include <stdlib.h>
#include <string.h>

#define CFB_MAXREGSECT 0xFFFFFFFAu
#define CFB_ENDOFCHAIN 0xFFFFFFFEu
#define CFB_NOSTREAM 0xFFFFFFFFu
#define CFB_HEADER_DIFAT 109
#define CFB_ENTRY 128

static uint16_t rd16(const uint8_t *p) {
  return (uint16_t) (p[0] | ((uint16_t) p[1] << 8));
}

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
         ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

/* Sector s, or NULL if it is a special value or not wholly in the buffer.
   Sector 0 follows the header, which occupies one sector's worth of bytes:
   512 in version 3, 4096 (mostly zeros) in version 4. */
static const uint8_t *sector_at(const cfb *c, uint32_t s) {
  if (s > CFB_MAXREGSECT || (uint64_t) s >= c->n_sectors) return NULL;
  return c->buf + ((uint64_t) s + 1u) * c->sector_size;
}

static int fat_next(const cfb *c, uint32_t s, uint32_t *next) {
  uint32_t per = c->sector_size / 4u;
  size_t index = s / per;
  const uint8_t *p;

  if (index >= c->n_fat_sectors) return 0;
  p = sector_at(c, c->fat_sectors[index]);
  if (p == NULL) return 0;
  *next = rd32(p + (s % per) * 4u);
  return 1;
}

static int minifat_next(const cfb *c, uint32_t m, uint32_t *next) {
  uint32_t per = c->sector_size / 4u;
  size_t index = m / per;
  const uint8_t *p;

  if (index >= c->n_minifat_sectors) return 0;
  p = sector_at(c, c->minifat_sectors[index]);
  if (p == NULL) return 0;
  *next = rd32(p + (m % per) * 4u);
  return 1;
}

static int push(uint32_t **v, size_t *n, size_t *cap, uint32_t x) {
  if (*n == *cap) {
    size_t grown = *cap ? *cap * 2 : 16;
    uint32_t *p = realloc(*v, grown * sizeof **v);
    if (p == NULL) return 0;
    *v = p;
    *cap = grown;
  }
  (*v)[(*n)++] = x;
  return 1;
}

/* Follows a FAT chain from `start`, collecting its sectors.
 *
 * `want` 0 means "to ENDOFCHAIN"; otherwise the walk stops once it has that
 * many, and a chain that ends sooner is malformed. A valid chain never visits
 * a sector twice, so one that does is malformed -- checked directly rather
 * than by length, because a stream that needs twenty sectors would otherwise
 * read one sector twenty times without the walk ever growing long. */
static cfb_status fat_chain(const cfb *c, uint32_t start, uint64_t want,
                            uint32_t **out, size_t *n_out) {
  uint32_t *v = NULL;
  size_t n = 0, cap = 0;
  uint32_t s = start;
  uint8_t *seen = calloc((size_t) (c->n_sectors / 8 + 1), 1);
  cfb_status st = CFB_OK;

  if (seen == NULL) return CFB_MEMORY;
  while (want == 0 ? s != CFB_ENDOFCHAIN : (uint64_t) n < want) {
    if (sector_at(c, s) == NULL || (seen[s / 8] & (1u << (s % 8)))) {
      st = CFB_MALFORMED;
      break;
    }
    seen[s / 8] |= (uint8_t) (1u << (s % 8));
    if (!push(&v, &n, &cap, s)) {
      st = CFB_MEMORY;
      break;
    }
    if (!fat_next(c, s, &s)) {
      st = CFB_MALFORMED;
      break;
    }
  }
  free(seen);
  if (st != CFB_OK) {
    free(v);
    return st;
  }
  *out = v;
  *n_out = n;
  return CFB_OK;
}

static const uint8_t *entry_at(const cfb *c, uint32_t i) {
  uint32_t per = c->sector_size / CFB_ENTRY;
  if ((uint64_t) i >= (uint64_t) c->n_dir_sectors * per) return NULL;
  return sector_at(c, c->dir_sectors[i / per]) + (size_t) (i % per) * CFB_ENTRY;
}

/* A version 3 file may leave garbage in the size's high 32 bits, and a
   reader must ignore it (2.6.3). */
static uint64_t entry_size(const cfb *c, const uint8_t *e) {
  uint64_t lo = rd32(e + 0x78);
  return c->version == 3 ? lo : lo | ((uint64_t) rd32(e + 0x7C) << 32);
}

void cfb_close(cfb *c) {
  free(c->fat_sectors);
  free(c->dir_sectors);
  free(c->minifat_sectors);
  free(c->mini_sectors);
  memset(c, 0, sizeof *c);
}

cfb_status cfb_open(cfb *c, const uint8_t *buf, size_t len) {
  static const uint8_t MAGIC[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
  cfb_status st;
  uint32_t n_fat, difat_next, n_difat, per, i;
  const uint8_t *root;
  size_t cap = 0;

  memset(c, 0, sizeof *c);
  if (buf == NULL || len < 512 || memcmp(buf, MAGIC, 8) != 0) return CFB_NOT_CFB;
  c->buf = buf;
  c->len = len;

  /* 2.2: version 3 means 512-byte sectors, version 4 means 4096, and the
     shift must agree; the byte order mark, the mini sector size and the
     mini stream cutoff are fixed. */
  c->version = rd16(buf + 0x1A);
  if (rd16(buf + 0x1C) != 0xFFFE) return CFB_MALFORMED;
  if (c->version == 3 && rd16(buf + 0x1E) == 9) {
    c->sector_size = 512;
  } else if (c->version == 4 && rd16(buf + 0x1E) == 12) {
    c->sector_size = 4096;
  } else {
    return CFB_MALFORMED;
  }
  if (rd16(buf + 0x20) != 6) return CFB_MALFORMED;
  c->mini_sector_size = 64;
  c->mini_cutoff = rd32(buf + 0x38);
  if (c->mini_cutoff != 4096) return CFB_MALFORMED;
  if (len < c->sector_size) return CFB_MALFORMED;
  c->n_sectors = (len - c->sector_size) / c->sector_size;
  per = c->sector_size / 4u;

  /* 2.5: the FAT's own sectors. 109 in the header, then DIFAT sectors, each
     holding per - 1 more and, last, the next DIFAT sector. */
  n_fat = rd32(buf + 0x2C);
  if ((uint64_t) n_fat > c->n_sectors) return CFB_MALFORMED;
  for (i = 0; i < n_fat && i < CFB_HEADER_DIFAT; i++) {
    if (!push(&c->fat_sectors, &c->n_fat_sectors, &cap, rd32(buf + 0x4C + i * 4u))) {
      cfb_close(c);
      return CFB_MEMORY;
    }
  }
  difat_next = rd32(buf + 0x44);
  n_difat = rd32(buf + 0x48);
  if ((uint64_t) n_difat > c->n_sectors) goto malformed;
  for (i = 0; i < n_difat && c->n_fat_sectors < n_fat; i++) {
    const uint8_t *d = sector_at(c, difat_next);
    uint32_t k;
    if (d == NULL) goto malformed;
    for (k = 0; k + 1 < per && c->n_fat_sectors < n_fat; k++) {
      if (!push(&c->fat_sectors, &c->n_fat_sectors, &cap, rd32(d + k * 4u))) {
        cfb_close(c);
        return CFB_MEMORY;
      }
    }
    difat_next = rd32(d + (per - 1u) * 4u);
  }
  if (c->n_fat_sectors != n_fat) goto malformed;
  for (i = 0; i < n_fat; i++) {
    if (sector_at(c, c->fat_sectors[i]) == NULL) goto malformed;
  }

  /* The directory, and the root entry it must start with. */
  st = fat_chain(c, rd32(buf + 0x30), 0, &c->dir_sectors, &c->n_dir_sectors);
  if (st != CFB_OK) goto fail;
  if (c->n_dir_sectors == 0) goto malformed;
  root = entry_at(c, 0);
  if (root[0x42] != 5) goto malformed;

  /* The miniFAT, and the mini stream: the root entry's chain, as long as its
     size says -- which the buffer must be able to back. */
  st = fat_chain(c, rd32(buf + 0x3C), 0, &c->minifat_sectors, &c->n_minifat_sectors);
  if (st != CFB_OK) goto fail;
  c->mini_size = entry_size(c, root);
  if (c->mini_size > (uint64_t) len) goto malformed;
  if (c->mini_size > 0) {
    st = fat_chain(c, rd32(root + 0x74),
                   (c->mini_size + c->sector_size - 1) / c->sector_size,
                   &c->mini_sectors, &c->n_mini_sectors);
    if (st != CFB_OK) goto fail;
  }
  return CFB_OK;

malformed:
  st = CFB_MALFORMED;
fail:
  cfb_close(c);
  return st;
}

/* 2.6.4 compares names case-insensitively, by upper-casing. `ascii` is
   ASCII, so a name matches only if every character is ASCII too: every high
   byte zero, never just the low bytes agreeing. */
static int name_is(const uint8_t *e, const char *ascii) {
  uint16_t len = rd16(e + 0x40);
  size_t want = strlen(ascii), i;

  if (len < 2 || len > 64 || len % 2 != 0 || (size_t) (len / 2 - 1) != want) {
    return 0;
  }
  for (i = 0; i < want; i++) {
    uint8_t lo = e[i * 2], a = (uint8_t) ascii[i];
    if (e[i * 2 + 1] != 0) return 0;
    if (lo >= 'a' && lo <= 'z') lo = (uint8_t) (lo - 'a' + 'A');
    if (a >= 'a' && a <= 'z') a = (uint8_t) (a - 'a' + 'A');
    if (lo != a) return 0;
  }
  return 1;
}

/* The root's children are a tree threaded through left and right sibling
   ids (2.6.4). It is walked rather than scanning every entry, so a stream of
   the same name inside a storage cannot be taken for the one at the root.
   `seen` means each entry is visited at most once, however the ids loop. */
static cfb_status find_at_root(const cfb *c, const char *name, const uint8_t **found) {
  uint64_t n_entries = (uint64_t) c->n_dir_sectors * (c->sector_size / CFB_ENTRY);
  uint8_t *seen;
  uint32_t *stack;
  size_t top = 0;
  cfb_status st = CFB_NOT_FOUND;
  uint32_t child = rd32(entry_at(c, 0) + 0x4C);

  *found = NULL;
  /* Ids are 32-bit, and NOSTREAM is one of them. */
  if (n_entries >= CFB_NOSTREAM) return CFB_MALFORMED;
  seen = calloc((size_t) n_entries, 1);
  /* An entry is pushed by each sibling pointing at it before it is visited,
     so up to two pushes per visited entry, plus the root's child. */
  stack = malloc(((size_t) n_entries * 2 + 1) * sizeof *stack);
  if (seen == NULL || stack == NULL) {
    free(seen);
    free(stack);
    return CFB_MEMORY;
  }
  if (child != CFB_NOSTREAM) stack[top++] = child;
  while (top > 0) {
    uint32_t id = stack[--top];
    const uint8_t *e = entry_at(c, id);
    uint32_t sides[2];
    int k;

    if (e == NULL || id == 0) { st = CFB_MALFORMED; break; }
    if (seen[id]) continue;
    seen[id] = 1;

    if (e[0x42] == 2 && name_is(e, name)) {
      if (*found != NULL) { st = CFB_MALFORMED; break; }
      *found = e;
      st = CFB_OK;
    }
    sides[0] = rd32(e + 0x44);
    sides[1] = rd32(e + 0x48);
    for (k = 0; k < 2; k++) {
      if (sides[k] == CFB_NOSTREAM) continue;
      if (sides[k] >= n_entries) { st = CFB_MALFORMED; goto done; }
      if (!seen[sides[k]]) stack[top++] = sides[k];
    }
  }
done:
  if (st == CFB_MALFORMED) *found = NULL;
  free(seen);
  free(stack);
  return st;
}

cfb_status cfb_stream(const cfb *c, const char *name, uint8_t **out, size_t *out_len) {
  const uint8_t *e;
  uint64_t size;
  uint8_t *data;
  cfb_status st;

  *out = NULL;
  *out_len = 0;
  st = find_at_root(c, name, &e);
  if (st != CFB_OK) return st;

  /* Nothing can be larger than the buffer it came out of, so this also
     bounds the allocation below by the input rather than by the file's
     word for it. */
  size = entry_size(c, e);
  if (size > (uint64_t) c->len) return CFB_MALFORMED;
  data = malloc(size > 0 ? (size_t) size : 1u);
  if (data == NULL) return CFB_MEMORY;

  if (size >= c->mini_cutoff) {
    uint32_t *chain = NULL;
    size_t n = 0, k;

    st = fat_chain(c, rd32(e + 0x74), (size + c->sector_size - 1) / c->sector_size,
                   &chain, &n);
    if (st != CFB_OK) { free(data); return st; }
    for (k = 0; k < n; k++) {
      uint64_t at = (uint64_t) k * c->sector_size;
      uint64_t take = size - at < c->sector_size ? size - at : c->sector_size;
      memcpy(data + at, sector_at(c, chain[k]), (size_t) take);
    }
    free(chain);
  } else if (size > 0) {
    /* The mini stream, in 64-byte mini sectors chained by the miniFAT. A mini
       sector never straddles a regular one, since 64 divides both sizes. */
    uint64_t at = 0;
    uint64_t n_mini = c->mini_size / c->mini_sector_size;
    uint32_t m = rd32(e + 0x74);
    uint8_t *seen = calloc((size_t) (n_mini / 8 + 1), 1);

    if (seen == NULL) {
      free(data);
      return CFB_MEMORY;
    }
    while (at < size) {
      uint64_t off = (uint64_t) m * c->mini_sector_size;
      uint64_t take = size - at < c->mini_sector_size ? size - at : c->mini_sector_size;
      size_t index = (size_t) (off / c->sector_size);

      /* In the mini stream, not past it, and not visited already. */
      if ((uint64_t) m >= n_mini || index >= c->n_mini_sectors ||
          (seen[m / 8] & (1u << (m % 8)))) {
        st = CFB_MALFORMED;
        break;
      }
      seen[m / 8] |= (uint8_t) (1u << (m % 8));
      memcpy(data + at, sector_at(c, c->mini_sectors[index]) + off % c->sector_size,
             (size_t) take);
      at += take;
      if (at < size && !minifat_next(c, m, &m)) {
        st = CFB_MALFORMED;
        break;
      }
    }
    free(seen);
    if (st != CFB_OK) {
      free(data);
      return st;
    }
  }

  *out = data;
  *out_len = (size_t) size;
  return CFB_OK;
}
