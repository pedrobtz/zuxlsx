# A ZIP archive built byte by byte, so that tests needing a non-workbook
# archive do not depend on an external zip program. CRAN guarantees neither
# `zip` nor Python, and utils::zip() shells out to the system one.
#
# One stored (uncompressed) entry, no data descriptor, no ZIP64. That is the
# smallest thing miniz will open and walk, which is all these tests need.
write_stored_zip <- function(path, name = "a.txt", contents = "hello") {
  name_raw <- charToRaw(name)
  data_raw <- charToRaw(contents)
  crc <- crc32_le(data_raw)
  n <- length(data_raw)

  # little-endian fixed-width field
  le <- function(x, bytes) {
    as.raw(vapply(
      seq_len(bytes),
      function(i) (as.numeric(x) %/% (256^(i - 1L))) %% 256,
      numeric(1)
    ))
  }

  local_header <- c(
    as.raw(c(0x50, 0x4b, 0x03, 0x04)), # signature
    le(20, 2), le(0, 2), le(0, 2),     # version needed, flags, method 0=stored
    le(0, 2), le(0, 2),                # mod time, mod date
    crc, le(n, 4), le(n, 4),           # crc32, compressed, uncompressed size
    le(length(name_raw), 2), le(0, 2)  # name length, extra length
  )
  central <- c(
    as.raw(c(0x50, 0x4b, 0x01, 0x02)), # signature
    le(20, 2), le(20, 2),              # version made by, version needed
    le(0, 2), le(0, 2),                # flags, method
    le(0, 2), le(0, 2),                # mod time, mod date
    crc, le(n, 4), le(n, 4),
    le(length(name_raw), 2), le(0, 2), le(0, 2), # name, extra, comment lengths
    le(0, 2), le(0, 2), le(0, 4),      # disk, internal attrs, external attrs
    le(0, 4)                           # offset of local header
  )
  central_size <- length(central) + length(name_raw)
  central_offset <- length(local_header) + length(name_raw) + n
  eocd <- c(
    as.raw(c(0x50, 0x4b, 0x05, 0x06)), # signature
    le(0, 2), le(0, 2),                # this disk, disk with central dir
    le(1, 2), le(1, 2),                # entries on this disk, entries total
    le(central_size, 4), le(central_offset, 4),
    le(0, 2)                           # comment length
  )

  writeBin(c(local_header, name_raw, data_raw, central, name_raw, eocd), path)
  path
}

# CRC-32 of `bytes`, as the four little-endian bytes a ZIP header wants.
#
# Written out rather than borrowed: zuxlsx has no Imports, and the tests should
# not be the thing that adds one. R's bitwXor() works on 32-bit *signed*
# integers, so the 0xEDB88320 polynomial is spelled as its signed value and the
# running value is allowed to go negative; bitwShiftR() shifts the unsigned bit
# pattern, which is exactly what CRC-32 needs.
crc32_le <- function(bytes) {
  poly <- -306674912L # 0xEDB88320
  table <- vapply(0:255, function(n) {
    c <- n
    for (k in 1:8) {
      c <- if (bitwAnd(c, 1L) == 1L) {
        bitwXor(poly, bitwShiftR(c, 1L))
      } else {
        bitwShiftR(c, 1L)
      }
    }
    c
  }, integer(1))

  crc <- -1L # 0xFFFFFFFF
  for (b in as.integer(bytes)) {
    idx <- bitwAnd(bitwXor(crc, b), 255L) + 1L
    crc <- bitwXor(table[idx], bitwShiftR(crc, 8L))
  }
  crc <- bitwXor(crc, -1L)
  if (crc < 0) crc <- crc + 2^32

  as.raw(vapply(
    1:4,
    function(i) (crc %/% (256^(i - 1L))) %% 256,
    numeric(1)
  ))
}
