# read_xlsx(range = ): the A1-style rectangle of design section 12.

test_that("column letters follow Excel's bijective base 26", {
  # Not ordinary base 26: there is no zero digit, so "AA" is 27, not 26.
  expect_identical(
    column_number(c("A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA")),
    c(1, 2, 26, 27, 28, 52, 53, 702, 703)
  )
  expect_identical(column_number("a"), 1)
  expect_true(is.na(column_number("A1")))
})

test_that("a rectangle takes only its own cells", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(4L, 4L))

  out <- read_xlsx(path, col_names = FALSE, range = "B2:C3")
  expect_identical(dim(out), c(2L, 2L))
  expect_identical(out$X1, c(6, 10))
  expect_identical(out$X2, c(7, 11))
})

test_that("a range may bound one axis only", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(4L, 4L))

  cols <- read_xlsx(path, col_names = FALSE, range = "A:B")
  expect_identical(dim(cols), c(4L, 2L))
  expect_identical(cols$X1, c(1, 5, 9, 13))

  rows <- read_xlsx(path, col_names = FALSE, range = "2:3")
  expect_identical(dim(rows), c(2L, 4L))
  expect_identical(rows$X1, c(5, 9))
})

test_that("the corners may be given in either order", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(4L, 4L))

  expect_identical(
    read_xlsx(path, col_names = FALSE, range = "C3:B2"),
    read_xlsx(path, col_names = FALSE, range = "B2:C3")
  )
})

test_that("the first row of the range supplies the names", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "ignored"), txt("B1", "also ignored")),
    c(txt("A2", "a"), txt("B2", "b")),
    c(num("A3", 1), num("B3", 2))
  )))

  # Row 1 is outside the range, so row 2 becomes the header.
  out <- read_xlsx(path, range = "A2:B3")
  expect_named(out, c("a", "b"))
  expect_identical(out$a, 1)
})

test_that("a range wider than the data still yields its own columns", {
  # Asking for A1:D2 on a two-column sheet gives four columns, the last two
  # empty. Silently narrowing would make the result depend on the data rather
  # than on what was asked for.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(2L, 2L))

  out <- read_xlsx(path, col_names = FALSE, range = "A1:D2")
  expect_identical(ncol(out), 4L)
  expect_identical(out$X3, c(NA, NA))
})

test_that("a range taller than the data still yields its own rows", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(2L, 2L))

  out <- read_xlsx(path, col_names = FALSE, range = "A1:B5")
  expect_identical(nrow(out), 5L)
  expect_identical(out$X1, c(1, 3, NA, NA, NA))
})

test_that("a range holding no cells is an empty data frame", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(2L, 2L))

  out <- read_xlsx(path, col_names = FALSE, range = "F10:G20")
  expect_s3_class(out, "data.frame")
  expect_identical(nrow(out), 0L)
})

test_that("a malformed range is an input error", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(2L, 2L))

  for (bad in c(
    "B2",        # not a range
    "A1:B2:C3",  # too many corners
    "A1:B",      # corners bounding different axes
    "1:B2",
    "",
    "A0:B2",     # rows count from 1
    "??:!!"
  )) {
    expect_error(
      read_xlsx(path, range = bad),
      class = "zuxlsx_input_error"
    )
  }
  expect_error(read_xlsx(path, range = 1), class = "zuxlsx_input_error")
  expect_error(read_xlsx(path, range = NA), class = "zuxlsx_input_error")
  expect_error(read_xlsx(path, range = c("A1:B2", "C1:D2")), class = "zuxlsx_input_error")
})

test_that("a range keeps its types and its epoch", {
  # Clipping must not disturb anything the cell layer established.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(
    cells = list(
      c(txt("A1", "skip"), txt("B1", "d")),
      c(txt("A2", "skip"), num("B2", 45324, s = 1))
    ),
    formats = c(0L, 14L)
  ))

  out <- read_xlsx(path, col_names = FALSE, range = "B2:B2")
  expect_identical(out$X1, as.Date("2024-02-02"))
})
