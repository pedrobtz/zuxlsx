# read_xlsx(): the column builders of design section 14, and the epoch
# handling of section 11.

test_that("a column takes the type its cells support", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "n"), txt("B1", "b"), txt("C1", "s"), txt("D1", "empty")),
    c(num("A2", 1), '<c r="B2" t="b"><v>1</v></c>', txt("C2", "x")),
    c(num("A3", 2.5), '<c r="B3" t="b"><v>0</v></c>', txt("C3", "y"))
  )))

  out <- read_xlsx(path)
  expect_identical(out$n, c(1, 2.5))
  expect_identical(out$b, c(TRUE, FALSE))
  expect_identical(out$s, c("x", "y"))
  # A column with no cells at all is logical NA, which promotes to anything.
  expect_identical(out$empty, c(NA, NA))
})

test_that("a column mixing types becomes character", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "mixed")),
    c(num("A2", 1)),
    c(txt("A3", "two"))
  )))

  expect_identical(read_xlsx(path)$mixed, c("1", "two"))
})

test_that("a cell error makes its column character rather than being dropped", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "v")),
    c(num("A2", 1)),
    c('<c r="A3" t="e"><v>#N/A</v></c>')
  )))

  expect_identical(read_xlsx(path)$v, c("1", "#N/A"))
})

test_that("blank cells keep their row alignment", {
  # The gap in the middle of one column must not pull the rows below it up.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "a"), txt("B1", "b")),
    c(num("A2", 1), num("B2", 10)),
    c(num("A3", 2)),
    c(num("A4", 3), num("B4", 30))
  )))

  out <- read_xlsx(path)
  expect_identical(out$a, c(1, 2, 3))
  expect_identical(out$b, c(10, NA, 30))
})

test_that("col_names = FALSE keeps the first row as data", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(c(num("A1", 1)), c(num("A2", 2)))))

  out <- read_xlsx(path, col_names = FALSE)
  expect_named(out, "X1")
  expect_identical(out$X1, c(1, 2))
})

test_that("duplicate and missing header names are made unique", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "x"), txt("B1", "x"), txt("D1", "z")),
    c(num("A2", 1), num("B2", 2), num("C2", 3), num("D2", 4))
  )))

  # Column C has no header, so it falls back to its position.
  expect_named(read_xlsx(path), c("x", "x_1", "X3", "z"))
})

test_that("col_names must be a single TRUE or FALSE", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_error(read_xlsx(path, col_names = NA), class = "zuxlsx_input_error")
  expect_error(read_xlsx(path, col_names = "yes"), class = "zuxlsx_input_error")
  expect_error(read_xlsx(path, col_names = c(TRUE, FALSE)), class = "zuxlsx_input_error")
})

test_that("a date column is a Date, read against the workbook's epoch", {
  # The same serial under the two epochs is four years and a day apart. This
  # is the failure that made reading workbookPr/@date1904 necessary.
  by_epoch <- function(date1904) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    parts <- styled_workbook_parts(
      cells = list(c(txt("A1", "d")), c(num("A2", 45324, s = 1))),
      formats = c(0L, 14L)
    )
    if (date1904) {
      parts[["xl/workbook.xml"]] <- sub(
        "<sheets>", '<workbookPr date1904="1"/><sheets>',
        parts[["xl/workbook.xml"]], fixed = TRUE
      )
    }
    write_workbook(path, parts)
    read_xlsx(path)$d
  }

  expect_identical(by_epoch(FALSE), as.Date("2024-02-02"))
  expect_identical(by_epoch(TRUE), as.Date("2028-02-03"))
})

test_that("the 1900 system's phantom leap day is accounted for", {
  # Excel counts a 29 February 1900 that never existed, so no single origin
  # works: serial 1 is 1 January 1900 and serial 61 is 1 March 1900. Using
  # 1899-12-30 throughout puts everything before March 1900 a day early.
  serial <- function(v) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    write_workbook(path, styled_workbook_parts(
      cells = list(c(txt("A1", "d")), c(num("A2", v, s = 1))),
      formats = c(0L, 14L)
    ))
    read_xlsx(path)$d
  }

  expect_identical(serial(1), as.Date("1900-01-01"))
  expect_identical(serial(59), as.Date("1900-02-28"))
  expect_identical(serial(61), as.Date("1900-03-01"))
  expect_identical(serial(45324), as.Date("2024-02-02"))
  # Serial 60 denotes no real date.
  expect_true(is.na(serial(60)))
})

test_that("a date carrying a time of day becomes POSIXct", {
  # Coercing to Date would silently drop the time.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = list(c(txt("A1", "d")), c(num("A2", 45324.5, s = 1))),
    formats = c(0L, 14L)
  ))

  out <- read_xlsx(path)$d
  expect_s3_class(out, "POSIXct")
  expect_identical(format(out, tz = "UTC"), "2024-02-02 12:00:00")
})

test_that("a committed fixture reads, and its 1904 epoch is honoured", {
  # blanks.xlsx really does carry date1904="1"; it was authored on a Mac.
  cells <- xlsx_cells(test_path("sheets", "blanks.xlsx"), 1)
  expect_true(attr(cells, "date1904"))

  out <- read_xlsx(test_path("sheets", "blanks.xlsx"), 1)
  expect_s3_class(out, "data.frame")
  expect_gt(nrow(out), 0L)
})
