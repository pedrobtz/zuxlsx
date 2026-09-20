# Structure-aware mutation of xlsx workbooks (design section 18).
#
# Sourced by tools/fuzz/run, not used directly.
#
# The format is a ZIP of XML parts, and mutating the bytes of the whole file
# is nearly useless against it: almost every random edit breaks the archive
# before a single XML parser is reached, so the reader refuses it in the first
# few instructions and nothing interesting is ever exercised. Unpacking,
# mutating one part, and repacking keeps the container valid and aims the
# damage at the code that actually has to cope with it.
#
# Every mutation is drawn from a seeded stream, so a finding can be reproduced
# by its index rather than kept as a binary.

source("tools/fixtures/zip.R")

# Reads every part of an xlsx as raw bytes.
unpack_parts <- function(path) {
  names <- utils::unzip(path, list = TRUE)$Name
  parts <- lapply(names, function(n) {
    con <- unz(path, n, open = "rb")
    on.exit(close(con))
    out <- raw(0)
    repeat {
      chunk <- readBin(con, "raw", 65536L)
      if (length(chunk) == 0L) break
      out <- c(out, chunk)
    }
    out
  })
  stats::setNames(parts, names)
}

# --- the mutations ----------------------------------------------------------
#
# Each takes and returns a raw vector, except the ones that act on the part
# list, which are applied in mutate_workbook() below.

flip_bytes <- function(bytes, rng, n = 4L) {
  if (length(bytes) == 0L) return(bytes)
  at <- sample(seq_along(bytes), min(n, length(bytes)))
  bytes[at] <- as.raw(sample(0:255, length(at), replace = TRUE))
  bytes
}

truncate_part <- function(bytes, rng) {
  if (length(bytes) < 2L) return(raw(0))
  bytes[seq_len(sample(seq_len(length(bytes) - 1L), 1L))]
}

grow_part <- function(bytes, rng) {
  # A part that claims far more content than it has, which is what a reader
  # sizing a buffer from a header has to survive.
  c(bytes, as.raw(sample(0:255, min(4096L, max(16L, length(bytes))), replace = TRUE)))
}

# Attribute values are where a reader converts text to a number, so they are
# where an overflow or a huge allocation is most likely to start.
extreme_attributes <- function(bytes, rng) {
  txt <- rawToChar(bytes[bytes != as.raw(0)])
  Encoding(txt) <- "bytes"
  big <- sample(c(
    "99999999999999999999", "-1", "0", "4294967296", "2147483648",
    "1e308", "0x7fffffff", ""
  ), 1L)
  txt <- sub('r="[A-Z]*[0-9]*"', paste0('r="', big, '"'), txt)
  txt <- sub('count="[0-9]*"', paste0('count="', big, '"'), txt)
  txt <- sub('numFmtId="[0-9]*"', paste0('numFmtId="', big, '"'), txt)
  charToRaw(txt)
}

unbalance_xml <- function(bytes, rng) {
  txt <- rawToChar(bytes[bytes != as.raw(0)])
  Encoding(txt) <- "bytes"
  charToRaw(switch(
    sample(1:4, 1L),
    sub("</", "<", txt, fixed = TRUE),
    sub("/>", ">", txt, fixed = TRUE),
    sub(">", "", txt, fixed = TRUE),
    paste0(txt, "<unclosed>")
  ))
}

PART_MUTATIONS <- list(
  flip = flip_bytes,
  truncate = truncate_part,
  grow = grow_part,
  attributes = extreme_attributes,
  unbalance = unbalance_xml
)

# Produces one mutant of `seed`, writing it to `out`. Returns a one-row
# description of what was done, so a finding can be explained without opening
# the file.
mutate_workbook <- function(seed, out, index) {
  set.seed(index)
  parts <- unpack_parts(seed)
  if (length(parts) == 0L) {
    return(NULL)
  }

  # Which part, weighted towards the ones with logic behind them rather than
  # the ones a reader merely copies.
  interesting <- grep(
    "workbook[.]xml$|sharedStrings[.]xml$|styles[.]xml$|sheet[0-9]*[.]xml$|[.]rels$|Content_Types",
    names(parts)
  )
  if (length(interesting) == 0L) interesting <- seq_along(parts)
  target <- names(parts)[sample(interesting, 1L)]

  action <- sample(c(names(PART_MUTATIONS), "drop", "duplicate"), 1L)
  if (action == "drop") {
    parts[[target]] <- NULL
  } else if (action == "duplicate") {
    # The same part name twice, which the format does not forbid and which
    # readers resolve differently from one another.
    parts <- c(parts, stats::setNames(list(parts[[target]]), target))
  } else {
    parts[[target]] <- PART_MUTATIONS[[action]](parts[[target]])
  }

  write_xlsx_parts(out, parts)
  data.frame(
    index = index, seed = basename(seed), part = target, action = action,
    stringsAsFactors = FALSE
  )
}
