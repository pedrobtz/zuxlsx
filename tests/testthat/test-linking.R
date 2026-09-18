# The LinkingTo wiring: <expat.h> and <miniz.h> found through LinkingTo,
# libzuxml.a and libzukomp.a found by ./configure and linked in. None of it is
# visible from R except by calling something that cannot work without it.

test_that("the native libraries are the ones we linked", {
  native <- zuxlsx_native()
  expect_named(native, c("xlsxio", "expat", "miniz"))

  # xlsxio is vendored here, so its version is pinned by
  # tools/vendor/manifest.tsv rather than by whatever is installed.
  # tools/vendor/verify checks this literal against the manifest and the
  # vendored header, which the tests cannot read: tools/ is not installed.
  expect_identical(native$xlsxio, "0.2.36")

  # These two came out of the archives. Asserting the shape rather than exact
  # versions: a zuxml or zukomp update should not fail this, but a build that
  # somehow linked nothing should.
  expect_match(native$expat, "^expat_[0-9]+\\.[0-9]+\\.[0-9]+$")
  expect_match(native$miniz, "^[0-9]+\\.[0-9]+\\.[0-9]+$")
})

test_that("a workbook's sheets can be listed", {
  # Everything at once: miniz opens the ZIP, locates xl/workbook.xml and
  # inflates it; Expat parses it; xlsxio walks the result. If either archive
  # is missing this does not reach an assertion.
  sheets <- xlsx_sheets(test_path("sheets", "utf8-sheet-names.xlsx"))
  expect_identical(sheets, c("µ", "∂"))
})

test_that("sheet names survive as UTF-8", {
  sheets <- xlsx_sheets(test_path("sheets", "utf8-sheet-names.xlsx"))
  expect_identical(Encoding(sheets), c("UTF-8", "UTF-8"))
})

test_that("a workbook with no optional parts still lists its sheet", {
  # No sharedStrings.xml and no styles.xml. Reaching workbook.xml must not
  # depend on parts that are allowed to be absent.
  expect_identical(
    xlsx_sheets(test_path("sheets", "no-styles-or-sharedStrings-parts.xlsx")),
    "Sheet1"
  )
})

test_that("a multi-sheet workbook reports them in workbook order", {
  expect_identical(
    xlsx_sheets(test_path("sheets", "blanks.xlsx")),
    c("different_rows", "same_row_first", "same_row_middle")
  )
})

test_that("every fixture in the corpus can be opened", {
  # The per-file manifest is the list of what we claim to handle; walking it
  # means a fixture added without a test still has to open.
  manifest <- read.delim(
    test_path("sheets", "MANIFEST.tsv"),
    stringsAsFactors = FALSE
  )
  expect_gt(nrow(manifest), 0L)

  for (file in manifest$file) {
    sheets <- xlsx_sheets(test_path("sheets", file))
    expect_type(sheets, "character")
    expect_gt(length(sheets), 0L)
  }
})
