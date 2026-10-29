# Structurally broken workbooks: the `invalid/` category of design section 17.4.
#
# These need no reading API. xlsx_sheets() already drives the whole native
# stack -- miniz opens the archive and inflates xl/workbook.xml, Expat parses
# it, xlsxio walks the result -- so a part that is missing, truncated or
# malformed exercises every layer of the pipeline today.
#
# Errors are asserted by condition class, never by message text.

test_that("an archive with no workbook part is an ooxml error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- NULL
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_ooxml_error")
})

test_that("an archive with no content types part is an ooxml error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["[Content_Types].xml"]] <- NULL
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_ooxml_error")
})

test_that("a workbook part that is not well-formed XML is an xml error", {
  # Not merely "an error". The distinction between XML that will not parse and
  # XML that parses but says nothing useful is what tells someone whether to
  # look at their file or at their expectations.
  for (bad in c(
    '<?xml version="1.0"?><workbook><sheets><sheet name="A"',
    "certainly not xml",
    "",
    '<?xml version="1.0"?><a><b></a></b>',
    '<?xml version="1.0"?><workbook attr=unquoted/>'
  )) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    parts <- workbook_parts()
    parts[["xl/workbook.xml"]] <- bad
    write_workbook(path, parts)

    expect_error(xlsx_sheets(path), class = "zuxlsx_xml_error")
  }
})

test_that("a malformed content types part is an xml error too", {
  # The other part that must parse before a worksheet can be found.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["[Content_Types].xml"]] <- '<?xml version="1.0"?><Types><Override'
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_xml_error")
})

test_that("an xml error names the part it is about", {
  # The class says what kind of failure it is; the message has to say where,
  # or the caller is no better off than with "not a workbook".
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- '<?xml version="1.0"?><workbook><sheets'
  write_workbook(path, parts)

  expect_error(
    xlsx_sheets(path),
    regexp = "xl/workbook[.]xml",
    class = "zuxlsx_xml_error"
  )
})

test_that("a workbook declaring no sheets is an ooxml error", {
  # A workbook always has at least one sheet. Returning character(0) here
  # would make a malformed file look like an empty-but-valid one.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0"?><workbook',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    "<sheets/></workbook>"
  )
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_ooxml_error")
})

test_that("an empty archive is an ooxml error, not a zip error", {
  # It opens as a ZIP perfectly well; it just is not a workbook.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_zip(path, list())

  expect_error(xlsx_sheets(path), class = "zuxlsx_ooxml_error")
})

test_that("a central directory pointing past the archive is a zip error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, central_offset_delta = 64L)

  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("an end-of-central-directory overcounting entries is a zip error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, entry_count_delta = 5L)

  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("a sheet name that is not valid UTF-8 is rejected", {
  # Expat must refuse the byte sequence rather than hand R a string that
  # violates its own encoding invariant.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- c(
    charToRaw(paste0(
      '<?xml version="1.0" encoding="UTF-8"?><workbook',
      ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
      '<sheets><sheet name="'
    )),
    as.raw(c(0xff, 0xfe, 0xfd)),
    charToRaw('" sheetId="1" r:id="rId1"/></sheets></workbook>')
  )
  write_workbook(path, parts)

  # Ill-formed UTF-8 is an XML well-formedness failure, not a workbook that
  # happens to say nothing.
  expect_error(xlsx_sheets(path), class = "zuxlsx_xml_error")
})

test_that("an unknown encoding declaration is rejected", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0" encoding="NOT-A-CHARSET"?><workbook',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>'
  )
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_xml_error")
})

test_that("a declared uncompressed size the entry cannot back is a zip error", {
  # The header claims half a gigabyte; the member holds a few hundred bytes.
  # This must be refused on the header arithmetic rather than by trying to
  # allocate what was asked for.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  entries[[3L]] <- zip_entry(
    "xl/workbook.xml",
    workbook_xml("S1"),
    declared_size = 512L * 1024L * 1024L
  )
  write_zip(path, entries)

  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("a relationship with no Id does not crash the process", {
  # Found by fuzzing, and the worst kind of defect this package could have: a
  # 1.5 KB workbook killed the whole R session with SIGSEGV. No condition, no
  # recovery, nothing to catch -- the process simply died.
  #
  # xlsxio read the Id attribute and compared it without checking for NULL,
  # and XML_Char_icmp is strcasecmp, which does not accept one. An element
  # carrying a worksheet Type and no Id was enough. Fixed by vendored patch
  # 0007; design section 16 requires that malformed input never do this.
  #
  # If this ever regresses the test does not fail, it takes the test process
  # with it -- which is a loud enough signal, and the reason the assertion is
  # simply that control returns at all.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- paste0(
    '<?xml version="1.0"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship',
    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"',
    ' Target="worksheets/sheet1.xml"/></Relationships>'
  )
  write_workbook(path, parts)

  # The worksheet is listed but cannot be reached. It reads as empty, the
  # way a chartsheet -- listed, with no worksheet part -- has to.
  expect_identical(xlsx_sheets(path), "Sheet1")
  expect_s3_class(xlsx_read(path), "data.frame")
  expect_identical(nrow(xlsx_cells(path, 1)), 0L)
})

test_that("a relationship with an empty Id does not crash either", {
  # The neighbouring case: present but empty, which is a different path
  # through the same comparison.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- paste0(
    '<?xml version="1.0"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id=""',
    ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"',
    ' Target="worksheets/sheet1.xml"/></Relationships>'
  )
  write_workbook(path, parts)

  expect_s3_class(xlsx_read(path), "data.frame")
})

test_that("a worksheet that breaks off is an error, not a shorter sheet", {
  # xlsxio reports the end of a worksheet and a parse error the same way, so
  # without a check a damaged sheet read as the rows before the damage.
  rows <- vapply(1:4, function(r) {
    paste0('<row r="', r, '">', num(paste0("A", r), r), "</row>")
  }, character(1))
  sheet <- function(body) {
    paste0(
      '<?xml version="1.0"?>',
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
      "<sheetData>", body, "</sheetData></worksheet>"
    )
  }
  intact <- sheet(paste0(rows, collapse = ""))
  injected <- sheet(paste0(c(rows[1:2], "<bogus attr=x>", rows[3:4]), collapse = ""))
  truncated <- substr(intact, 1L, nchar(intact) - 40L)

  for (damaged in list(injected, truncated)) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    parts <- workbook_parts()
    parts[["xl/worksheets/sheet1.xml"]] <- damaged
    write_workbook(path, parts)

    expect_error(xlsx_read(path, col_names = FALSE), class = "zuxlsx_xml_error")
    expect_error(xlsx_cells(path), class = "zuxlsx_xml_error")
    expect_error(xlsx_rows(path), class = "zuxlsx_xml_error")
    expect_error(
      xlsx_stream_cells(path, 1, function(cells) NULL),
      class = "zuxlsx_xml_error"
    )
  }

  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- intact
  write_workbook(path, parts)
  expect_identical(xlsx_read(path, col_names = FALSE)$X1, c(1, 2, 3, 4))
})

test_that("a worksheet that breaks off is reported after the chunks before it", {
  # Chunks already handed over stay handed over, but the read does not end
  # quietly.
  rows <- vapply(1:6, function(r) {
    paste0('<row r="', r, '">', num(paste0("A", r), r), "</row>")
  }, character(1))
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<sheetData>", paste0(rows[1:4], collapse = ""), "<bogus attr=x>"
  )
  write_workbook(path, parts)

  seen <- 0L
  expect_error(
    xlsx_stream_cells(path, 1, function(cells) seen <<- seen + nrow(cells),
                    chunk_size = 2L),
    class = "zuxlsx_xml_error"
  )
  expect_gte(seen, 2L)
})

test_that("a damaged shared-string table or styles part is an error naming it", {
  # Both are read before the worksheet. Damaged, they used to load as far as
  # the damage and no further: strings went missing or wrong, and a styles
  # part cut short turned dates into plain numbers.
  with_part <- function(name, contents, declared_crc = NULL) {
    path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = parent.frame())
    parts <- styled_workbook_parts(
      c('<c r="A1" t="s"><v>0</v></c>', num("B1", 45324, s = 1)),
      formats = c(0L, 14L)
    )
    parts[["xl/sharedStrings.xml"]] <- paste0(
      '<?xml version="1.0"?>',
      '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
      "<si><t>zero</t></si></sst>"
    )
    parts[["xl/_rels/workbook.xml.rels"]] <- sub(
      "</Relationships>",
      paste0(
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/',
        'officeDocument/2006/relationships/sharedStrings" ',
        'Target="sharedStrings.xml"/></Relationships>'
      ),
      parts[["xl/_rels/workbook.xml.rels"]],
      fixed = TRUE
    )
    if (!is.null(contents)) parts[[name]] <- contents
    entries <- lapply(names(parts), function(n) {
      zip_entry(n, parts[[n]], declared_crc = if (n == name) declared_crc)
    })
    write_zip(path, entries)
    path
  }

  intact <- with_part("xl/sharedStrings.xml", NULL)
  cells <- xlsx_cells(intact)
  expect_identical(cells$value[1], "zero")
  expect_identical(as.character(cells$type[2]), "date")

  truncated_strings <- with_part(
    "xl/sharedStrings.xml",
    '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>zero</t></si><si><t>on'
  )
  broken_styles <- with_part(
    "xl/styles.xml",
    '<?xml version="1.0"?><styleSheet><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"'
  )
  for (path in c(truncated_strings, broken_styles)) {
    cond <- tryCatch(xlsx_cells(path), error = identity)
    expect_s3_class(cond, "zuxlsx_xml_error")
    expect_error(xlsx_read(path), class = "zuxlsx_xml_error")
  }
  expect_identical(
    .Call(C_xlsx_cells, normalizePath(truncated_strings), "Sheet1", NULL)$value$part,
    "xl/sharedStrings.xml"
  )
  expect_identical(
    .Call(C_xlsx_cells, normalizePath(broken_styles), "Sheet1", NULL)$value$part,
    "xl/styles.xml"
  )

  bad_crc <- with_part("xl/sharedStrings.xml", NULL, declared_crc = as.raw(c(0, 0, 0, 0)))
  expect_error(xlsx_cells(bad_crc), class = "zuxlsx_zip_error")
  expect_identical(
    .Call(C_xlsx_cells, normalizePath(bad_crc), "Sheet1", NULL)$status, "part_zip"
  )
})

test_that("a flipped byte in a deflated worksheet is an error", {
  # The third damage #38 reproduced: bytes changed inside the DEFLATE stream
  # used to end the worksheet early, as if it were complete.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- grid_workbook(200L, 5L)
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]], deflate = TRUE))
  sheet <- which(names(parts) == "xl/worksheets/sheet1.xml")
  data <- entries[[sheet]]$data
  mid <- length(data) %/% 2L
  data[mid + 0:7] <- xor(data[mid + 0:7], as.raw(0xFF))
  entries[[sheet]]$data <- data
  write_zip(path, entries)

  cond <- tryCatch(xlsx_read(path, col_names = FALSE), error = identity)
  expect_true(inherits(cond, "zuxlsx_zip_error") || inherits(cond, "zuxlsx_xml_error"))
})
