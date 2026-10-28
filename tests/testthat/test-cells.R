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

test_that("a bracket is elapsed time only when it holds h, m or s alone", {
  # Locale tags and colours carry those letters too: [$$-en-US] is what Excel
  # writes for US dollars, and [Magenta] and [White] are colours. Reading any
  # of them as elapsed time turned money into dates.
  path <- withr::local_tempfile(fileext = ".xlsx")
  codes <- c(
    "164" = "[$$-en-US]#,##0.00", "165" = "[Magenta]#,##0.00",
    "166" = "[White]0", "167" = "[$CHF-de-CH] #,##0.00",
    "168" = "[h]:mm", "169" = "[mm]:ss", "170" = "[SS]",
    "171" = "[$-409]h:mm AM/PM"
  )
  write_workbook(path, styled_workbook_parts(
    cells = vapply(
      seq_along(codes),
      function(i) num(paste0(LETTERS[i], 1), 1234.5, s = i),
      character(1)
    ),
    formats = c(0L, as.integer(names(codes))),
    custom = codes
  ))

  expect_identical(
    as.character(xlsx_cells(path)$type),
    c(rep("number", 4), rep("date", 4))
  )
})

test_that("the East Asian and Thai built-in date formats are dates", {
  # ECMA-376 18.8.30: Excel writes these ids without declaring a format code.
  ids <- c(27L, 36L, 50L, 58L, 71L, 81L, 26L, 37L, 49L, 59L, 70L, 82L)
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = vapply(
      seq_along(ids),
      function(i) num(paste0(LETTERS[i], 1), 45324, s = i),
      character(1)
    ),
    formats = c(0L, ids)
  ))

  expect_identical(
    as.character(xlsx_cells(path)$type),
    c(rep("date", 6), rep("number", 6))
  )
})

test_that("an ISO 8601 date cell gets the serial an Excel number would have", {
  iso_cells <- c(
    '<c r="A1" t="d"><v>2024-02-02</v></c>',
    '<c r="B1" t="d"><v>2024-02-02T12:00:00</v></c>',
    '<c r="C1" t="d"><v>1900-01-01</v></c>',
    '<c r="D1" t="d"><v>1900-03-01</v></c>',
    '<c r="E1" t="d"><v>2024-02-02T06:00:00.5Z</v></c>',
    '<c r="F1" t="d"><v>not a date</v></c>',
    '<c r="G1" t="d"><v>2024-02-30</v></c>'
  )
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(iso_cells))

  cells <- xlsx_cells(path)
  expect_identical(
    as.character(cells$type),
    c(rep("date", 5), "string", "string")
  )
  expect_identical(cells$number[1:4], c(45324, 45324.5, 1, 61))
  expect_equal(cells$number[5], 45324 + (6 * 3600 + 0.5) / 86400)
  # Text that is not a date survives as text.
  expect_identical(cells$value[6:7], c("not a date", "2024-02-30"))
  expect_true(all(is.na(cells$number[6:7])))
})

test_that("an ISO 8601 date cell counts from the workbook's own epoch", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- styled_workbook_parts('<c r="A1" t="d"><v>1904-01-02</v></c>')
  parts[["xl/workbook.xml"]] <- sub(
    "<sheets>", '<workbookPr date1904="1"/><sheets>', parts[["xl/workbook.xml"]],
    fixed = TRUE
  )
  write_workbook(path, parts)

  cells <- xlsx_cells(path)
  expect_true(attr(cells, "date1904"))
  expect_identical(cells$number, 1)
})

test_that("a sheet position must be a whole number", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, workbook_parts(c("First", "Second")))

  expect_error(xlsx_cells(path, 1.7), class = "zuxlsx_input_error")
  expect_error(xlsx_cells(path, Inf), class = "zuxlsx_input_error")
  expect_error(xlsx_cells(path, NaN), class = "zuxlsx_input_error")
  expect_identical(xlsx_cells(path, 2), xlsx_cells(path, 2L))
})

test_that("the R cell type labels match the native enum", {
  # CELL_TYPES is indexed by the C enum's value; this is what holds the two
  # together, since nothing in R can.
  # Source-tree only: an installed package has no src/.
  src_file <- test_path("..", "..", "src", "zuxlsx.c")
  skip_if_not(file.exists(src_file), "package source not available")
  src <- readLines(src_file, warn = FALSE)
  enum <- regmatches(src, regexpr("ZU_CELL_[A-Z]+ = [0-9]+", src))
  labels <- tolower(sub("ZU_CELL_([A-Z]+) = .*", "\\1", enum))
  values <- as.integer(sub(".* = ", "", enum))
  expect_identical(CELL_TYPES[values + 1L], labels)
})
