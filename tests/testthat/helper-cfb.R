# A CFB container writer that follows [MS-CFB] where tools/make-ole2.R does
# not need to: streams under 4096 bytes go in the mini stream, version 4's
# 4096-byte sectors are available, and FATs too large for the header's 109
# DIFAT entries continue into DIFAT sectors.
#
# It exists to build the containers the stream reader is tested on, each
# shaped for one assertion -- a v4 file, a DIFAT sector, a stream of every
# size class -- which no committed fixture covers. It is checked against
# helper-ole2.R's reader, written separately, as well as against the C.

cfb_build <- function(streams, version = 3L) {
  ss <- if (version == 3L) 512L else 4096L
  per <- ss %/% 4L
  u32 <- function(x) {
    x <- as.numeric(x)
    as.raw(c(x %% 256, (x %/% 256) %% 256, (x %/% 65536) %% 256,
             (x %/% 16777216) %% 256))
  }
  u32s <- function(xs) unlist(lapply(xs, u32), use.names = FALSE)
  u16 <- function(x) as.raw(c(x %% 256, x %/% 256))
  pad <- function(bytes, to) c(bytes, raw((-length(bytes)) %% to))

  ENDOFCHAIN <- 0xFFFFFFFE
  FREESECT <- 0xFFFFFFFF

  # The mini stream: every stream under the cutoff, each padded to whole
  # 64-byte mini sectors and chained in the miniFAT.
  small <- vapply(streams, length, 0) < 4096
  mini <- raw(0)
  minifat <- numeric(0)
  mini_start <- rep(ENDOFCHAIN, length(streams))
  for (i in which(small & vapply(streams, length, 0) > 0)) {
    n <- ceiling(length(streams[[i]]) / 64)
    first <- length(mini) / 64
    mini_start[i] <- first
    minifat <- c(minifat, if (n > 1) first + seq_len(n - 1) else numeric(0),
                 ENDOFCHAIN)
    mini <- c(mini, pad(streams[[i]], 64))
  }

  # Regular-sector payloads, in the order they are laid out.
  entries_n <- length(streams) + 1L
  payloads <- list(
    mini = mini,
    minifat = if (length(minifat)) pad(u32s(minifat), ss) else raw(0),
    dir = raw(ceiling(entries_n * 128 / ss) * ss)
  )
  for (i in which(!small)) payloads[[paste0("s", i)]] <- streams[[i]]
  n_of <- vapply(payloads, function(p) ceiling(length(p) / ss), 0)

  # How many FAT and DIFAT sectors: enough FAT for every sector, itself and
  # the DIFAT's included.
  data_n <- sum(n_of)
  n_fat <- 1
  repeat {
    n_difat <- if (n_fat > 109) ceiling((n_fat - 109) / (per - 1)) else 0
    if (n_fat * per >= data_n + n_fat + n_difat) break
    n_fat <- n_fat + 1
  }
  fat_secs <- seq_len(n_fat) - 1
  difat_secs <- n_fat + seq_len(n_difat) - 1
  start <- n_fat + n_difat + c(0, cumsum(n_of))[seq_along(n_of)]
  names(start) <- names(payloads)
  total <- n_fat + n_difat + data_n

  fat <- rep(FREESECT, n_fat * per)
  fat[fat_secs + 1] <- 0xFFFFFFFD            # FATSECT
  fat[difat_secs + 1] <- 0xFFFFFFFC          # DIFSECT
  for (nm in names(payloads)) {
    if (n_of[[nm]] == 0) next
    secs <- start[[nm]] + seq_len(n_of[[nm]]) - 1
    fat[secs + 1] <- c(secs[-1], ENDOFCHAIN)
  }
  chain_start <- function(nm) if (n_of[[nm]] > 0) start[[nm]] else ENDOFCHAIN

  # The directory: the root, then the streams as a right-leaning chain of
  # siblings, which is a legal tree.
  entry <- function(name, type, first, size, right = FREESECT, child = FREESECT) {
    chars <- utf8ToInt(name)
    utf16 <- c(as.raw(as.vector(rbind(chars %% 256, chars %/% 256))), raw(2))
    c(c(utf16, raw(64 - length(utf16))), u16(length(utf16)), as.raw(type),
      as.raw(1), u32(FREESECT), u32(right), u32(child), raw(16), u32(0),
      raw(16), u32(first), u32(size), u32(0))
  }
  dir <- entry("Root Entry", 5, chain_start("mini"), length(mini),
               child = if (length(streams)) 1 else FREESECT)
  for (i in seq_along(streams)) {
    first <- if (small[i]) mini_start[i] else chain_start(paste0("s", i))
    dir <- c(dir, entry(names(streams)[i], 2, first, length(streams[[i]]),
                        right = if (i < length(streams)) i + 1 else FREESECT))
  }
  payloads$dir <- pad(dir, ss)

  difat <- c(fat_secs, rep(FREESECT, max(0, 109 - n_fat)))
  header <- c(
    as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)), raw(16),
    u16(0x3E), u16(version), u16(0xFFFE), u16(if (version == 3L) 9 else 12),
    u16(6), raw(6),
    u32(if (version == 3L) 0 else n_of[["dir"]]),
    u32(n_fat), u32(start[["dir"]]), u32(0), u32(4096),
    u32(chain_start("minifat")), u32(n_of[["minifat"]]),
    u32(if (n_difat) difat_secs[1] else ENDOFCHAIN), u32(n_difat),
    u32s(difat[1:109])
  )
  header <- c(header, raw(ss - length(header)))

  # The FAT beyond the header's 109 entries, per - 1 to a DIFAT sector, the
  # last slot pointing at the next.
  rest <- if (n_fat > 109) fat_secs[-(1:109)] else numeric(0)
  difat_bytes <- raw(0)
  for (k in seq_len(n_difat)) {
    take <- rest[seq_len(min(per - 1, length(rest)))]
    rest <- rest[-seq_along(take)]
    slots <- c(take, rep(FREESECT, per - 1 - length(take)),
               if (k < n_difat) difat_secs[k + 1] else ENDOFCHAIN)
    difat_bytes <- c(difat_bytes, u32s(slots))
  }

  body <- unlist(lapply(names(payloads), function(nm) pad(payloads[[nm]], ss)),
                 use.names = FALSE)
  out <- c(header, u32s(fat), difat_bytes, body)
  stopifnot(length(out) == ss * (total + 1))
  out
}

# Where a directory entry with this name starts, found by its UTF-16LE name,
# for tests that corrupt one entry. The first match, and the name must be
# unique in the container for that to mean anything.
cfb_entry_offset <- function(bytes, name) {
  chars <- utf8ToInt(name)
  needle <- c(as.raw(as.vector(rbind(chars %% 256, chars %/% 256))), raw(2))
  n <- length(needle)
  starts <- which(bytes == needle[1])
  hit <- starts[vapply(starts, function(i) {
    i + n - 1 <= length(bytes) && identical(bytes[i:(i + n - 1)], needle)
  }, logical(1))]
  hit <- hit[(hit - 1) %% 128 == 0]
  if (length(hit) == 0L) stop("no directory entry named ", name)
  hit[1] - 1
}

# Writes a little-endian 32-bit value at a 0-based offset.
put_u32 <- function(bytes, at, x) {
  x <- as.numeric(x)
  bytes[at + 1:4] <- as.raw(c(x %% 256, (x %/% 256) %% 256,
                              (x %/% 65536) %% 256, (x %/% 16777216) %% 256))
  bytes
}

# The R reader in helper-ole2.R takes a path.
cfb_stream_r <- function(bytes, name) {
  path <- tempfile(fileext = ".cfb")
  on.exit(unlink(path))
  writeBin(bytes, path)
  cfb_stream(path, name)
}
