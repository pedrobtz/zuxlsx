# xlsx_read_cells(): the callback reader of design section 12.
#
# This is the one entry that calls R while the archive and the parser are
# open, so several of these tests are about what happens when that call does
# something other than return -- which is the reason the native handles are
# owned by external pointers rather than by the C stack.

test_that("the chunks together are the whole worksheet", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(12L, 4L))

  seen <- list()
  xlsx_read_cells(path, 1, function(cells) {
    seen[[length(seen) + 1L]] <<- cells
  }, chunk_size = 7L)

  all_cells <- do.call(rbind, seen)
  whole <- xlsx_cells(path, 1)
  expect_gt(length(seen), 1L)
  expect_identical(all_cells$row, whole$row)
  expect_identical(all_cells$col, whole$col)
  expect_identical(all_cells$value, whole$value)
  expect_identical(as.character(all_cells$type), as.character(whole$type))
})

test_that("a chunk never splits a row", {
  # A callback that sees half a row cannot do anything useful with it, so the
  # chunk size is a lower bound and the boundary falls between rows.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(10L, 5L))

  xlsx_read_cells(path, 1, function(cells) {
    counts <- table(cells$row)
    # Every row present in a chunk is present in full.
    expect_true(all(counts == 5L))
  }, chunk_size = 3L)
})

test_that("returning FALSE stops the read", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(100L, 4L))

  seen <- 0L
  stopped <- xlsx_read_cells(path, 1, function(cells) {
    seen <<- seen + nrow(cells)
    FALSE
  }, chunk_size = 8L)

  expect_true(stopped)
  # Far short of the 400 cells the worksheet holds.
  expect_lt(seen, 100L)
})

test_that("reading to the end reports that it was not stopped", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(4L, 2L))

  expect_false(xlsx_read_cells(path, 1, function(cells) NULL))
  # Any value other than FALSE continues, including TRUE.
  expect_false(xlsx_read_cells(path, 1, function(cells) TRUE))
})

test_that("an error in the callback propagates and leaves nothing open", {
  # The archive and the parser are open when the callback runs, and an error
  # unwinds past every close() on the C stack. If the handles were not owned
  # by R, this would leak them and the next read could fail.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(40L, 4L))

  expect_error(
    xlsx_read_cells(path, 1, function(cells) stop("from the callback"),
                    chunk_size = 8L),
    "from the callback"
  )

  # The proof that nothing was left open: the same file reads normally.
  seen <- 0L
  xlsx_read_cells(path, 1, function(cells) seen <<- seen + nrow(cells))
  expect_identical(seen, 160L)
})

test_that("repeated aborted reads do not accumulate", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(20L, 4L))

  for (i in 1:25) {
    expect_error(
      xlsx_read_cells(path, 1, function(cells) stop("x"), chunk_size = 4L),
      "x"
    )
  }
  expect_false(xlsx_read_cells(path, 1, function(cells) NULL))
})

test_that("each chunk carries the workbook epoch", {
  # read_xlsx() needs it to convert a date, and a caller assembling columns
  # from chunks needs it for the same reason.
  expect_true(
    local({
      got <- NULL
      xlsx_read_cells(path_to("blanks.xlsx"), 1, function(cells) {
        got <<- attr(cells, "date1904")
      })
      got
    })
  )
})

test_that("a worksheet can be chosen by name", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, workbook_parts(c("one", "two")))

  seen <- 0L
  xlsx_read_cells(path, "two", function(cells) seen <<- seen + nrow(cells))
  expect_gt(seen, 0L)
})

test_that("bad arguments are input errors", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path)

  expect_error(xlsx_read_cells(path, 1, "not a function"),
               class = "zuxlsx_input_error")
  expect_error(xlsx_read_cells(path, 1, function(x) NULL, chunk_size = 0),
               class = "zuxlsx_input_error")
  expect_error(xlsx_read_cells(path, 1, function(x) NULL, chunk_size = NA),
               class = "zuxlsx_input_error")
  expect_error(xlsx_read_cells(path, 99, function(x) NULL),
               class = "zuxlsx_sheet_error")
})

test_that("an unreadable file fails before the callback is ever called", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(charToRaw("not a zip"), path)

  called <- FALSE
  expect_error(
    xlsx_read_cells(path, "Sheet1", function(cells) called <<- TRUE),
    class = "zuxlsx_error"
  )
  expect_false(called)
})
