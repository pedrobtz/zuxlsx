# A minimal OLE2/CFB directory reader, in R.
#
# Two jobs. It checks that the fixtures tools/make-ole2.R writes are actually
# readable as CFB rather than merely starting with the right eight bytes --
# written from [MS-CFB] independently of the writer, so a misreading would
# have to be made twice in the same direction to go unnoticed.
#
# And it is the specification for the C the reader needs. Telling a
# password-protected .xlsx from a legacy .xls means getting exactly this far
# into the container and no further: header, FAT, directory, names. Everything
# below is bounds-checked the way that C will have to be, because these are
# hostile-input paths -- a workbook that arrives encrypted is a workbook
# somebody else produced.

SECTOR <- 512L
ENDOFCHAIN <- 0xFFFFFFFE

# Little-endian scalars. Read as doubles, because a sector number runs past
# what a signed 32-bit integer holds and R has no unsigned type.
le_u16 <- function(raw, at) {
  as.numeric(raw[at + 1L]) + 256 * as.numeric(raw[at + 2L])
}
le_u32 <- function(raw, at) {
  sum(as.numeric(raw[(at + 1L):(at + 4L)]) * c(1, 256, 65536, 16777216))
}

cfb_read <- function(path) {
  bytes <- readBin(path, "raw", file.size(path))
  expect_gte(length(bytes), SECTOR)

  magic <- as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
  expect_identical(bytes[1:8], magic)

  # A v3 container uses 512-byte sectors; v4 uses 4096. Only v3 is generated
  # here, and a reader that assumes the size rather than reading the shift is
  # a reader that misparses every v4 file it meets.
  sector_shift <- le_u16(bytes, 0x1E)
  expect_identical(sector_shift, 9)

  sector_at <- function(n) {
    from <- SECTOR + n * SECTOR
    # The bound is the point: a corrupt FAT entry pointing past the end of
    # the file is the first thing a hostile container does.
    expect_lte(from + SECTOR, length(bytes))
    bytes[(from + 1L):(from + SECTOR)]
  }

  first_dir <- le_u32(bytes, 0x30)
  fat_start <- le_u32(bytes, 0x4C)
  fat <- sector_at(fat_start)
  fat_entry <- function(n) le_u32(fat, n * 4L)

  # Walk the directory chain. Bounded by the number of sectors in the file,
  # so a FAT that loops back on itself terminates instead of hanging.
  max_sectors <- length(bytes) %/% SECTOR
  dir_bytes <- raw(0)
  sec <- first_dir
  seen <- 0L
  while (sec != ENDOFCHAIN && seen < max_sectors) {
    dir_bytes <- c(dir_bytes, sector_at(sec))
    sec <- fat_entry(sec)
    seen <- seen + 1L
  }
  expect_lt(seen, max_sectors)

  entries <- list()
  n_entries <- length(dir_bytes) %/% 128L
  for (i in seq_len(n_entries)) {
    at <- (i - 1L) * 128L
    type <- as.integer(dir_bytes[at + 0x42 + 1L])
    if (type == 0L) next                       # unallocated
    name_len <- le_u16(dir_bytes, at + 0x40)
    if (name_len < 2 || name_len > 64) next
    # UTF-16LE, and the recorded length includes the terminating null.
    chars <- dir_bytes[(at + 1L):(at + name_len - 2L)]
    name <- rawToChar(chars[seq(1L, length(chars), by = 2L)])
    entries[[length(entries) + 1L]] <- list(
      name = name,
      type = type,
      size = le_u32(dir_bytes, at + 0x78)
    )
  }
  entries
}

cfb_stream_names <- function(path) {
  vapply(cfb_read(path), function(e) e$name, character(1))
}

ole2_fixture <- function(name) {
  path <- test_path("fixtures", "ole2", name)
  skip_if(!file.exists(path), paste0(name, " fixture is missing"))
  path
}
