# A ZIP archive built byte by byte, so that tests needing a hand-made archive
# do not depend on an external zip program. CRAN guarantees neither `zip` nor
# Python, and utils::zip() shells out to the system one.
#
# Stored (uncompressed) entries only, no data descriptors, no ZIP64. That is
# the smallest thing miniz will open and walk. Building the bytes by hand is
# not incidental: the adversarial tests need to write a central directory that
# disagrees with the local headers, declare a size an entry does not have, or
# name the same member twice, and no ZIP library will produce those on request.

# little-endian fixed-width field
le <- function(x, bytes) {
  as.raw(vapply(
    seq_len(bytes),
    function(i) (as.numeric(x) %/% (256^(i - 1L))) %% 256,
    numeric(1)
  ))
}

as_raw_contents <- function(x) if (is.raw(x)) x else charToRaw(x)

# One member of an archive. `declared_size` and `declared_crc` override what
# goes into the headers without changing the bytes actually stored, which is
# how the lying-header tests are built.
zip_entry <- function(name, contents, declared_size = NULL, declared_crc = NULL) {
  data_raw <- as_raw_contents(contents)
  list(
    name = name,
    data = data_raw,
    size = if (is.null(declared_size)) length(data_raw) else declared_size,
    crc = if (is.null(declared_crc)) crc32_le(data_raw) else declared_crc
  )
}

# Assembles `entries` into a ZIP at `path`.
#
# `central_offset_delta` and `entry_count_delta` perturb the end-of-central-
# directory record so that a structurally valid archive can be made to point
# somewhere wrong, which is what the corrupt-central-directory tests need.
write_zip <- function(path,
                      entries,
                      central_offset_delta = 0L,
                      entry_count_delta = 0L) {
  local_blocks <- list()
  central_blocks <- list()
  offset <- 0L

  for (e in entries) {
    name_raw <- charToRaw(e$name)
    n_stored <- length(e$data)

    local_header <- c(
      as.raw(c(0x50, 0x4b, 0x03, 0x04)), # signature
      le(20, 2), le(0, 2), le(0, 2),     # version needed, flags, method 0=stored
      le(0, 2), le(0, 2),                # mod time, mod date
      e$crc, le(n_stored, 4), le(e$size, 4),
      le(length(name_raw), 2), le(0, 2)  # name length, extra length
    )
    central <- c(
      as.raw(c(0x50, 0x4b, 0x01, 0x02)), # signature
      le(20, 2), le(20, 2),              # version made by, version needed
      le(0, 2), le(0, 2),                # flags, method
      le(0, 2), le(0, 2),                # mod time, mod date
      e$crc, le(n_stored, 4), le(e$size, 4),
      le(length(name_raw), 2), le(0, 2), le(0, 2), # name, extra, comment
      le(0, 2), le(0, 2), le(0, 4),      # disk, internal attrs, external attrs
      le(offset, 4)                      # offset of local header
    )

    local_blocks[[length(local_blocks) + 1L]] <- c(local_header, name_raw, e$data)
    central_blocks[[length(central_blocks) + 1L]] <- c(central, name_raw)
    offset <- offset + length(local_header) + length(name_raw) + n_stored
  }

  local_bytes <- unlist(local_blocks, use.names = FALSE)
  central_bytes <- unlist(central_blocks, use.names = FALSE)

  eocd <- c(
    as.raw(c(0x50, 0x4b, 0x05, 0x06)), # signature
    le(0, 2), le(0, 2),                # this disk, disk with central dir
    le(length(entries) + entry_count_delta, 2),
    le(length(entries) + entry_count_delta, 2),
    le(length(central_bytes), 4),
    le(length(local_bytes) + central_offset_delta, 4),
    le(0, 2)                           # comment length
  )

  writeBin(c(local_bytes, central_bytes, eocd), path)
  path
}

# The original single-entry helper, kept as the narrow case it always was.
write_stored_zip <- function(path, name = "a.txt", contents = "hello") {
  write_zip(path, list(zip_entry(name, contents)))
}


# --- Minimal OOXML workbooks -------------------------------------------------
#
# A workbook assembled from parts, each of which a test can replace or drop.
# xlsx_sheets() drives the whole native stack -- miniz opens the archive,
# locates and inflates xl/workbook.xml, Expat parses it, and xlsxio resolves
# each <sheet> through the relationship part -- so malformed parts exercise
# every layer without needing the reading API.

CONTENT_TYPES_XML <- paste0(
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
  '<Default Extension="xml" ContentType="application/xml"/>',
  '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
  '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
  '</Types>'
)

ROOT_RELS_XML <- paste0(
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>',
  '</Relationships>'
)

workbook_xml <- function(sheets = "Sheet1", rid = NULL) {
  if (is.null(rid)) rid <- paste0("rId", seq_along(sheets))
  entries <- paste0(
    '<sheet name="', sheets, '" sheetId="', seq_along(sheets),
    '" r:id="', rid, '"/>',
    collapse = ""
  )
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<sheets>', entries, '</sheets></workbook>'
  )
}

workbook_rels_xml <- function(n = 1L, targets = NULL) {
  if (is.null(targets)) targets <- paste0("worksheets/sheet", seq_len(n), ".xml")
  entries <- paste0(
    '<Relationship Id="rId', seq_along(targets),
    '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"',
    ' Target="', targets, '"/>',
    collapse = ""
  )
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    entries, '</Relationships>'
  )
}

SHEET_XML <- paste0(
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  '<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>x</t></is></c></row></sheetData>',
  '</worksheet>'
)

# The parts of a well-formed one-sheet workbook, as a named list so that a test
# can override one, drop one, or add a duplicate before handing it to
# write_workbook().
workbook_parts <- function(sheets = "Sheet1") {
  n <- length(sheets)
  parts <- list(
    "[Content_Types].xml"          = CONTENT_TYPES_XML,
    "_rels/.rels"                  = ROOT_RELS_XML,
    "xl/workbook.xml"              = workbook_xml(sheets),
    "xl/_rels/workbook.xml.rels"   = workbook_rels_xml(n)
  )
  for (i in seq_len(n)) {
    parts[[paste0("xl/worksheets/sheet", i, ".xml")]] <- SHEET_XML
  }
  parts
}

# Writes `parts` (a named list of part name -> contents) as an .xlsx.
write_workbook <- function(path, parts = workbook_parts(), ...) {
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  write_zip(path, entries, ...)
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


# --- Workbooks with number formats -------------------------------------------
#
# A date in OOXML is a number whose style carries a date format, so testing
# date handling means building styles.xml as well as the worksheet. `cells` is
# the literal <c> elements, so a test can write exactly the cell it means.

# `formats` is numFmtId per cellXfs entry: style index i selects formats[i+1].
# 0 is General, 14 is the built-in short date, and anything from 164 up needs
# a formatCode in <numFmts>, supplied through `custom`.
styles_xml <- function(formats = 0L, custom = NULL) {
  numfmts <- ""
  if (length(custom)) {
    numfmts <- paste0(
      '<numFmts count="', length(custom), '">',
      paste0(
        '<numFmt numFmtId="', names(custom), '" formatCode="', custom, '"/>',
        collapse = ""
      ),
      "</numFmts>"
    )
  }
  paste0(
    '<?xml version="1.0"?>',
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    numfmts,
    '<cellXfs count="', length(formats), '">',
    paste0('<xf numFmtId="', formats, '"/>', collapse = ""),
    "</cellXfs></styleSheet>"
  )
}

# A one-sheet workbook whose worksheet holds `cells` and whose styles.xml is
# built from `formats` and `custom`.
#
# `cells` is either a character vector of <c> elements, making a single row, or
# a list of such vectors, one per row.
styled_workbook_parts <- function(cells, formats = 0L, custom = NULL) {
  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- paste0(
    '<?xml version="1.0"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1"',
    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"',
    ' Target="worksheets/sheet1.xml"/>',
    '<Relationship Id="rId2"',
    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"',
    ' Target="styles.xml"/>',
    "</Relationships>"
  )
  rows <- if (is.list(cells)) cells else list(cells)
  parts[["xl/styles.xml"]] <- styles_xml(formats, custom)
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<sheetData>",
    paste0(
      "<row r=\"", seq_along(rows), "\">",
      vapply(rows, paste0, character(1), collapse = ""),
      "</row>",
      collapse = ""
    ),
    "</sheetData></worksheet>"
  )
  parts
}


# Single <c> elements, for tests that spell a worksheet out cell by cell.
# These live here rather than in a test file because testthat shuffles test
# order, and a helper defined at the top of one file is not reliably in scope
# when its tests run.
txt <- function(ref, s) {
  paste0('<c r="', ref, '" t="inlineStr"><is><t>', s, "</t></is></c>")
}

num <- function(ref, v, s = NULL) {
  paste0(
    '<c r="', ref, '"',
    if (is.null(s)) "" else paste0(' s="', s, '"'),
    "><v>", v, "</v></c>"
  )
}


# Reads a single column of numeric literals back out of a workbook.
read_literals <- function(literals) {
  path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = parent.frame())
  write_workbook(path, styled_workbook_parts(c(
    list(txt("A1", "v")),
    lapply(seq_along(literals), function(i) num(paste0("A", i + 1L), literals[i]))
  )))
  read_xlsx(path)$v
}
