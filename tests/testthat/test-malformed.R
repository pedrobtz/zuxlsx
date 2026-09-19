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
