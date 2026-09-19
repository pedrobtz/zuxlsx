# Conventions the suite enforces on itself.

test_that("no test file defines a helper at top level", {
  # testthat shuffles test order, and a function defined alongside the tests
  # that call it is not reliably in scope when they run: the failure appears
  # only under devtools::test(shuffle = TRUE), only sometimes, and reads as a
  # missing function rather than as a scoping problem.
  #
  # Shared builders belong in a helper-*.R file, which testthat always loads
  # first. This is checked rather than remembered because the mistake was made
  # three times while writing this suite, each time caught only by a shuffled
  # run that happened to order the files badly.
  files <- list.files(test_path("."), pattern = "^test-.*[.]R$", full.names = TRUE)
  expect_gt(length(files), 0L)

  offenders <- character(0)
  for (file in files) {
    lines <- readLines(file, warn = FALSE)
    if (any(grepl("^[a-zA-Z_.][a-zA-Z0-9_.]* *<- *function", lines))) {
      offenders <- c(offenders, basename(file))
    }
  }
  expect_identical(offenders, character(0))
})
