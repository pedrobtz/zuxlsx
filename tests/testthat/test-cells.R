# The cell reader: design sections 12-13.
#
# Cell types are the point. OOXML records a cell's type in its t= attribute
# and its number format through a style index, and vendored patch 0003 is what
# makes either reachable -- before it, every cell arrived as undifferentiated
# text and xl/styles.xml was never parsed at all. These tests are what keeps
# that patch honest.

test_that("each OOXML cell type is classified", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(c(
    '<c r="A1"><v>42.5</v></c>',
    '<c r="B1" t="b"><v>1</v></c>',
    '<c r="C1" t="b"><v>0</v></c>',
    '<c r="D1" t="e"><v>#DIV/0!</v></c>',
    '<c r="E1" t="inlineStr"><is><t>inline</t></is></c>',
    '<c r="F1" t="str"><v>formula</v></c>',
    '<c r="G1"/>'
  )))

  cells <- xlsx_cells(path)
  expect_identical(
    as.character(cells$type),
    c("number", "boolean", "boolean", "error", "string", "string", "blank")
  )
  expect_identical(cells$number[1:3], c(42.5, 1, 0))
  expect_identical(cells$value[4], "#DIV/0!")
})

test_that("a number carrying a date format is a date", {
  # The number is identical in all three cells; only the style differs. This
  # is the whole reason styles.xml has to be parsed.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = c(
      '<c r="A1"><v>45324</v></c>',
      '<c r="B1" s="1"><v>45324</v></c>',
      '<c r="C1" s="2"><v>45324</v></c>'
    ),
    formats = c(0L, 14L, 164L),
    custom = c("164" = "yyyy-mm-dd")
  ))

  cells <- xlsx_cells(path)
  expect_identical(as.character(cells$type), c("number", "date", "date"))
  # The serial number is handed back as written; the epoch is the workbook's
  # property, so no conversion happens here.
  expect_identical(unique(cells$number), 45324)
})

test_that("a format code with date letters inside a string literal is not a date", {
  # "day" 0.00 contains d, a and y, but they are literal text. A scanner that
  # ignored quoting would call this a date.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = c('<c r="A1" s="1"><v>7</v></c>', '<c r="B1" s="2"><v>7</v></c>'),
    formats = c(0L, 165L, 166L),
    custom = c("165" = "&quot;day&quot; 0.00", "166" = "d mmm yyyy")
  ))

  expect_identical(as.character(xlsx_cells(path)$type), c("number", "date"))
})

test_that("an elapsed-time format is a date, a colour format is not", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = c('<c r="A1" s="1"><v>1.5</v></c>', '<c r="B1" s="2"><v>1.5</v></c>'),
    formats = c(0L, 167L, 168L),
    custom = c("167" = "[h]:mm:ss", "168" = "[Red]0.00")
  ))

  expect_identical(as.character(xlsx_cells(path)$type), c("date", "number"))
})

test_that("a workbook with no styles part still reads its cells", {
  # styles.xml is optional. Its absence means no cell is a date, not a failure.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    '<sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>'
  )
  write_workbook(path, parts)

  cells <- xlsx_cells(path)
  expect_identical(as.character(cells$type), "number")
})

test_that("positions are reported from one, with blanks kept in place", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(c(
    '<c r="A1"><v>1</v></c>',
    '<c r="C1"><v>3</v></c>'
  )))

  cells <- xlsx_cells(path)
  # The gap at B1 must be reported rather than closed up, or column
  # alignment is lost.
  expect_identical(cells$col, c(1, 2, 3))
  expect_identical(as.character(cells$type), c("number", "blank", "number"))
  expect_true(all(cells$row == 1))
})

test_that("a worksheet can be chosen by name or by position", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, workbook_parts(c("First", "Second")))

  expect_identical(xlsx_cells(path, 1), xlsx_cells(path, "First"))
  expect_identical(xlsx_cells(path, 2), xlsx_cells(path, "Second"))
})

test_that("a worksheet position outside the workbook is a sheet error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_error(xlsx_cells(path, 2), class = "zuxlsx_sheet_error")
  expect_error(xlsx_cells(path, 0), class = "zuxlsx_sheet_error")
})

test_that("a worksheet name that is not in the workbook is a sheet error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_error(xlsx_cells(path, "Nope"), class = "zuxlsx_sheet_error")
})

test_that("a sheet argument that is not a name or a position is an input error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_error(xlsx_cells(path, NULL), class = "zuxlsx_input_error")
  expect_error(xlsx_cells(path, c(1, 2)), class = "zuxlsx_input_error")
  expect_error(xlsx_cells(path, NA), class = "zuxlsx_input_error")
})

test_that("shared strings are resolved", {
  # The one part of the reader that is not streamed, so worth asserting
  # directly rather than through a fixture.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- styled_workbook_parts(c(
    '<c r="A1" t="s"><v>0</v></c>',
    '<c r="B1" t="s"><v>1</v></c>'
  ))
  parts[["xl/_rels/workbook.xml.rels"]] <- sub(
    "</Relationships>",
    paste0(
      '<Relationship Id="rId3"',
      ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"',
      ' Target="sharedStrings.xml"/></Relationships>'
    ),
    parts[["xl/_rels/workbook.xml.rels"]],
    fixed = TRUE
  )
  parts[["xl/sharedStrings.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">',
    "<si><t>alpha</t></si><si><t>été</t></si></sst>"
  )
  write_workbook(path, parts)

  cells <- xlsx_cells(path)
  expect_identical(cells$value, c("alpha", "été"))
  expect_identical(as.character(cells$type), c("string", "string"))
})

test_that("cells can be read from a committed fixture", {
  cells <- xlsx_cells(test_path("sheets", "inlineStr.xlsx"), 1)
  expect_s3_class(cells, "data.frame")
  expect_named(cells, c("row", "col", "type", "value", "number"))
  expect_gt(nrow(cells), 0L)
})
