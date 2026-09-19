# Spreadsheets zuxlsx cannot read, told apart from files that are broken.
#
# Both cases used to surface as corruption: an encrypted workbook as a ZIP
# error, an xlsb as a workbook declaring no worksheets. Neither is true, and
# both send the reader of the message looking for a problem that is not there.

test_that("an OLE2 file is reported as a format, not as a broken archive", {
  # The eight byte compound-file signature. A real encrypted workbook carries
  # a whole CFB structure after it; detection needs only the header, which is
  # why this fixture can be built here rather than fetched.
  path <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(
    c(as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)), raw(512)),
    path
  )

  expect_error(xlsx_sheets(path), class = "zuxlsx_unsupported_format_error")
  expect_error(xlsx_cells(path), class = "zuxlsx_unsupported_format_error")
  expect_error(read_xlsx(path), class = "zuxlsx_unsupported_format_error")
})

test_that("an OLE2 file is still a zuxlsx_error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(
    c(as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)), raw(512)),
    path
  )
  expect_error(xlsx_sheets(path), class = "zuxlsx_error")
})

test_that("a file that merely starts like OLE2 is not misreported", {
  # Seven of the eight bytes. The check must be the whole signature, or a
  # truncated archive that happens to begin similarly is given the wrong
  # explanation.
  path <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(c(as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0x00)), raw(64)), path)

  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("an xlsb is reported as a format, not as an empty workbook", {
  # An xlsb is a real OPC package: a ZIP whose content types and relationships
  # are XML, and whose workbook and worksheets are binary. Everything below is
  # what a genuine one looks like, minus the BIFF12 payload.
  path <- withr::local_tempfile(fileext = ".xlsb")
  parts <- list(
    "[Content_Types].xml" = paste0(
      '<?xml version="1.0"?>',
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
      '<Override PartName="/xl/workbook.bin"',
      ' ContentType="application/vnd.ms-excel.sheet.binary.macroEnabled.main"/>',
      "</Types>"
    ),
    "_rels/.rels" = ROOT_RELS_XML,
    "xl/workbook.bin" = "not xml, binary records"
  )
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_unsupported_format_error")
  expect_error(read_xlsx(path), class = "zuxlsx_unsupported_format_error")
})

test_that("a ZIP that is neither a workbook nor an xlsb is still an ooxml error", {
  # The xlsb check must not become the explanation for every archive that
  # fails to declare a worksheet.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_stored_zip(path)

  expect_error(xlsx_sheets(path), class = "zuxlsx_ooxml_error")
})

test_that("detecting formats does not disturb a workbook that reads", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_identical(xlsx_sheets(path), "Sheet1")
})
