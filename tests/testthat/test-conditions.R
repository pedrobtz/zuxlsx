# Errors are asserted by condition class, never by message text: the classes
# are the contract, the wording is not. Snapshots below cover the wording.

test_that("a path that is not one usable string is an input error", {
  expect_error(xlsx_sheets(1), class = "zuxlsx_input_error")
  expect_error(xlsx_sheets(c("a", "b")), class = "zuxlsx_input_error")
  expect_error(xlsx_sheets(NA_character_), class = "zuxlsx_input_error")
  expect_error(xlsx_sheets(character(0)), class = "zuxlsx_input_error")
})

test_that("a missing file is an input error, not a zip error", {
  missing <- withr::local_tempfile(fileext = ".xlsx")
  expect_false(file.exists(missing))
  expect_error(xlsx_sheets(missing), class = "zuxlsx_input_error")
})

test_that("a directory is an input error, not a zip error", {
  dir <- withr::local_tempdir()
  expect_error(xlsx_sheets(dir), class = "zuxlsx_input_error")
})

test_that("a file that is not a ZIP is a zip error", {
  # Reaches miniz, which has to refuse it rather than read past the end of a
  # two-byte archive.
  not_xlsx <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(charToRaw("no"), not_xlsx)
  expect_error(xlsx_sheets(not_xlsx), class = "zuxlsx_zip_error")
})

test_that("a truncated workbook is a zip error", {
  whole <- readBin(
    test_path("sheets", "blanks.xlsx"),
    "raw",
    file.size(test_path("sheets", "blanks.xlsx"))
  )
  truncated <- withr::local_tempfile(fileext = ".xlsx")

  # Losing the end of central directory, and losing only its tail.
  for (keep in c(length(whole) %/% 2L, length(whole) - 10L)) {
    writeBin(whole[seq_len(keep)], truncated)
    expect_error(xlsx_sheets(truncated), class = "zuxlsx_zip_error")
  }
})

test_that("a valid ZIP that is not a workbook is an ooxml error", {
  # Previously this returned character(0), which made a wrong file look like a
  # workbook that happened to have no sheets. A workbook always has one.
  zip <- withr::local_tempfile(fileext = ".xlsx")
  write_stored_zip(zip)
  expect_error(xlsx_sheets(zip), class = "zuxlsx_ooxml_error")
})

test_that("every zuxlsx error is catchable as zuxlsx_error", {
  not_xlsx <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(charToRaw("no"), not_xlsx)

  for (thunk in list(
    function() xlsx_sheets(1),
    function() xlsx_sheets(not_xlsx)
  )) {
    caught <- tryCatch(thunk(), zuxlsx_error = function(e) e)
    expect_s3_class(caught, "zuxlsx_error")
    expect_s3_class(caught, "error")
  }
})

test_that("conditions carry the path they are about", {
  not_xlsx <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(charToRaw("no"), not_xlsx)

  caught <- tryCatch(xlsx_sheets(not_xlsx), zuxlsx_error = function(e) e)
  expect_identical(caught$path, normalizePath(not_xlsx, winslash = "/"))
})

test_that("an unrecognised native status is reported, not silently dropped", {
  # Guards the switch() in zuxlsx_unwrap(): a status added in C without a
  # branch here must not turn into a NULL return.
  expect_error(
    zuxlsx_unwrap(list(status = "not_a_real_status", value = NULL)),
    class = "zuxlsx_error"
  )
})

test_that("error messages are stable", {
  # Deterministic basenames inside a temp directory: the transform scrubs the
  # directory, and the names have to be stable for the snapshot to be. A
  # withr::local_tempfile() name is random and would rewrite the snapshot on
  # every run.
  dir <- withr::local_tempdir()
  not_xlsx <- file.path(dir, "not-a-zip.xlsx")
  writeBin(charToRaw("no"), not_xlsx)
  not_workbook <- file.path(dir, "not-a-workbook.xlsx")
  write_stored_zip(not_workbook)

  scrub <- function(lines) sub("'[^']*/([^'/]+)'", "'<tmp>/\\1'", lines)

  expect_snapshot(error = TRUE, transform = scrub, {
    xlsx_sheets(1)
    xlsx_sheets("no-such-file.xlsx")
    xlsx_sheets(not_xlsx)
    xlsx_sheets(not_workbook)
  })
})
