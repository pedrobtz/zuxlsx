# Strict OOXML: the ISO/IEC 29500 namespace family.
#
# Excel writes this when asked for "Strict Open XML Spreadsheet". It differs
# from the transitional form Excel writes by default only in its namespace
# URIs, and the relationship Type attributes are among them -- which is what a
# reader has to match on to locate a worksheet.
#
# Getting this wrong failed silently rather than loudly: the sheet list still
# worked, because that reads workbook.xml directly, and every worksheet then
# read as empty with no error. That is why these tests assert on content
# rather than on the absence of a condition.

test_that("a strict workbook's cells are read, not silently dropped", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, strict_workbook_parts("Strict"))

  expect_identical(xlsx_sheets(path), "Strict")
  cells <- xlsx_cells(path, 1)
  expect_identical(nrow(cells), 2L)
  expect_identical(cells$number, c(1, 2))
})

test_that("a strict workbook builds columns like any other", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, strict_workbook_parts(
    "Strict",
    cells = c(num("A1", 10), num("B1", 20))
  ))

  out <- read_xlsx(path, col_names = FALSE)
  expect_identical(dim(out), c(1L, 2L))
  expect_identical(out$X1, 10)
})

test_that("listing sheets is not enough to call a strict workbook readable", {
  # The exact shape of the defect this guards: xlsx_sheets() succeeded while
  # read_xlsx() returned a data frame with no columns and no rows.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, strict_workbook_parts("Strict"))

  expect_gt(length(xlsx_sheets(path)), 0L)
  expect_gt(ncol(read_xlsx(path, col_names = FALSE)), 0L)
  expect_gt(nrow(read_xlsx(path, col_names = FALSE)), 0L)
})

test_that("a transitional workbook is unaffected", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_identical(xlsx_sheets(path), "Sheet1")
  expect_s3_class(read_xlsx(path, 1), "data.frame")
})

test_that("a relationship type from another vocabulary is not accepted", {
  # Matching on the last path component alone would take "worksheet" from any
  # namespace at all. The base has to match too.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- paste0(
    '<?xml version="1.0"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://example.invalid/relationships/worksheet"',
    ' Target="worksheets/sheet1.xml"/></Relationships>'
  )
  write_workbook(path, parts)

  # The worksheet is not located, so no cells are found.
  expect_identical(nrow(xlsx_cells(path, 1)), 0L)
})
