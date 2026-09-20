# A minimal ZIP writer, in pure R.
#
# Sourced by the fixture generators. CRAN guarantees neither a `zip` program
# nor Python, and utils::zip() shells out to the system one, so the bytes are
# assembled here. Stored (uncompressed) entries only: a fixture is a few
# kilobytes, and an uncompressed archive is one less thing between the
# generator and a reader trying to explain a surprising result.
#
# Deliberately free of anything that varies between runs -- every modification
# time is zero -- so that regenerating produces identical bytes and `--check`
# means something.

le <- function(x, bytes) {
  as.raw(vapply(
    seq_len(bytes),
    function(i) (as.numeric(x) %/% (256^(i - 1L))) %% 256,
    numeric(1)
  ))
}

crc32_le <- function(bytes) {
  poly <- -306674912L # 0xEDB88320
  table <- vapply(0:255, function(n) {
    c <- n
    for (k in 1:8) {
      c <- if (bitwAnd(c, 1L) == 1L) bitwXor(poly, bitwShiftR(c, 1L)) else bitwShiftR(c, 1L)
    }
    c
  }, integer(1))
  crc <- -1L
  for (b in as.integer(bytes)) {
    crc <- bitwXor(table[bitwAnd(bitwXor(crc, b), 255L) + 1L], bitwShiftR(crc, 8L))
  }
  crc <- bitwXor(crc, -1L)
  if (crc < 0) crc <- crc + 2^32
  as.raw(vapply(1:4, function(i) (crc %/% (256^(i - 1L))) %% 256, numeric(1)))
}

# `parts` is a named list of part name -> contents, each either a string or a
# raw vector. Raw is accepted so that a mutated part can hold bytes that are
# not valid text at all, which is most of what a fuzzer produces.
write_xlsx_parts <- function(path, parts) {
  local_blocks <- list()
  central_blocks <- list()
  offset <- 0L

  for (nm in names(parts)) {
    name_raw <- charToRaw(nm)
    data_raw <- if (is.raw(parts[[nm]])) parts[[nm]] else charToRaw(parts[[nm]])
    n <- length(data_raw)
    crc <- crc32_le(data_raw)

    local <- c(
      as.raw(c(0x50, 0x4b, 0x03, 0x04)),
      le(20, 2), le(0, 2), le(0, 2),
      le(0, 2), le(0, 2),
      crc, le(n, 4), le(n, 4),
      le(length(name_raw), 2), le(0, 2)
    )
    central <- c(
      as.raw(c(0x50, 0x4b, 0x01, 0x02)),
      le(20, 2), le(20, 2), le(0, 2), le(0, 2),
      le(0, 2), le(0, 2),
      crc, le(n, 4), le(n, 4),
      le(length(name_raw), 2), le(0, 2), le(0, 2),
      le(0, 2), le(0, 2), le(0, 4),
      le(offset, 4)
    )
    local_blocks[[length(local_blocks) + 1L]] <- c(local, name_raw, data_raw)
    central_blocks[[length(central_blocks) + 1L]] <- c(central, name_raw)
    offset <- offset + length(local) + length(name_raw) + n
  }

  local_bytes <- unlist(local_blocks, use.names = FALSE)
  central_bytes <- unlist(central_blocks, use.names = FALSE)
  eocd <- c(
    as.raw(c(0x50, 0x4b, 0x05, 0x06)),
    le(0, 2), le(0, 2),
    le(length(parts), 2), le(length(parts), 2),
    le(length(central_bytes), 4), le(length(local_bytes), 4),
    le(0, 2)
  )
  writeBin(c(local_bytes, central_bytes, eocd), path)
  invisible(path)
}
