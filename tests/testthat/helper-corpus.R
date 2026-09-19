# Locates a workbook in the committed corpus.
#
# Defined in a helper rather than at the top of a test file: testthat shuffles
# test order, and a function defined alongside the tests that use it is not
# reliably in scope when they run.
path_to <- function(file) {
  test_path("sheets", file)
}
