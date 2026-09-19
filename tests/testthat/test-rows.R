# xlsx_rows(): the row-oriented view of design section 12.

test_that("a worksheet comes back one character vector per row", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "a"), txt("B1", "b")),
    c(num("A2", 1), txt("B2", "two"))
  )))

  rows <- xlsx_rows(path)
  expect_type(rows, "list")
  expect_length(rows, 2L)
  expect_identical(rows[[1L]], c("a", "b"))
  # No type inference: a number is its text.
  expect_identical(rows[[2L]], c("1", "two"))
})

test_that("every row is as wide as the widest", {
  # The nth element of each vector has to be the nth column, or a consumer
  # cannot line rows up at all.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "a")),
    c(txt("A2", "x"), txt("B2", "y"), txt("C2", "z"))
  )))

  rows <- xlsx_rows(path)
  expect_identical(lengths(rows), c(3L, 3L))
  expect_identical(rows[[1L]], c("a", NA, NA))
})

test_that("a blank cell is NA rather than an empty string", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "a"), txt("C1", "c"))
  )))

  expect_identical(xlsx_rows(path)[[1L]], c("a", NA, "c"))
})

test_that("an omitted row is kept as a row of NA", {
  rows <- xlsx_rows(path_to("blanks.xlsx"), "same_row_middle")
  expect_length(rows, 4L)
  expect_identical(rows[[3L]], c(NA_character_, NA_character_))
  expect_identical(rows[[4L]], c("2", "b"))
})

test_that("a worksheet with no cells is an empty list", {
  expect_identical(xlsx_rows(path_to("empty-sheets.xlsx"), "empty"), list())
})

test_that("rows and cells agree about a fixture", {
  rows <- xlsx_rows(path_to("no-styles-or-sharedStrings-parts.xlsx"))
  cells <- xlsx_cells(path_to("no-styles-or-sharedStrings-parts.xlsx"))
  expect_length(rows, max(cells$row))
  expect_true(all(lengths(rows) == max(cells$col)))
})
