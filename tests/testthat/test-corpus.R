# Content of the committed interoperability corpus (design sections 17.1-17.3).
#
# These seven workbooks were produced by Excel and other real writers, not by
# this package's test helpers, which is what makes them worth asserting on: a
# synthetic file only proves zuxlsx can read what zuxlsx wrote.
#
# Until read_xlsx() existed a fixture could only be checked for opening, and
# test-linking.R still does that for every manifest entry. What follows checks
# that the values come back, which is the part that was unverifiable before.

test_that("blanks.xlsx keeps blank cells in their places", {
  # Three worksheets, each putting the gap somewhere different.
  first <- read_xlsx(path_to("blanks.xlsx"), "different_rows")
  expect_named(first, c("x", "y"))
  expect_identical(first$x, c(NA, 1))
  expect_identical(first$y, c("a", NA))

  expect_identical(
    read_xlsx(path_to("blanks.xlsx"), "same_row_first"),
    data.frame(x = 1, y = "a", stringsAsFactors = FALSE)
  )
  # Rows 1, 2 and 4: row 3 is absent from the XML entirely, which is what the
  # worksheet's name refers to. The blank row has to survive as a row, or the
  # values on either side of it move next to each other and every row index
  # below the gap is wrong.
  expect_identical(
    read_xlsx(path_to("blanks.xlsx"), "same_row_middle"),
    data.frame(
      x = c(1, NA, 2),
      y = c("a", NA, "b"),
      stringsAsFactors = FALSE
    )
  )
})

test_that("blanks.xlsx is a 1904 workbook", {
  # Authored on a Mac. Worth pinning as a property of the corpus: it is the
  # only committed workbook that would expose a hard-coded 1900 epoch.
  expect_true(attr(xlsx_cells(path_to("blanks.xlsx"), 1), "date1904"))
})

test_that("a worksheet with no cells at all reads as an empty data frame", {
  out <- read_xlsx(path_to("empty-sheets.xlsx"), "empty")
  expect_s3_class(out, "data.frame")
  expect_identical(nrow(out), 0L)
  expect_identical(ncol(out), 0L)
})

test_that("a worksheet with only a header row keeps its names and no rows", {
  out <- read_xlsx(path_to("empty-sheets.xlsx"), "header_only")
  expect_named(out, c("var1", "var2"))
  expect_identical(nrow(out), 0L)
  # Nothing to infer a type from, so the columns stay logical.
  expect_true(all(vapply(out, is.logical, logical(1))))
})

test_that("inline strings are read without a shared string table", {
  # inlineStr.xlsx has no xl/sharedStrings.xml part at all.
  out <- read_xlsx(path_to("inlineStr.xlsx"))
  expect_identical(dim(out), c(1L, 9L))
  expect_identical(out$ID, "RQ11610")
  expect_identical(out$Name, "requirement")
  expect_identical(out$Type, "Textual Requirement")
  expect_identical(out$NN, 1)
})

test_that("a cell with no value node is missing rather than wrong", {
  # missing-v-node-xlsx.xlsx holds a formula cell with no cached <v>. It has
  # to come back as NA; inventing a value or dropping the column would both
  # shift the data.
  out <- read_xlsx(path_to("missing-v-node-xlsx.xlsx"))
  expect_named(out, c("A", "B", "A + B"))
  expect_identical(out$A, 1)
  expect_identical(out$B, 2)
  expect_true(is.na(out[["A + B"]]))
})

test_that("a workbook missing both optional parts reads in full", {
  # No sharedStrings.xml and no styles.xml.
  out <- read_xlsx(path_to("no-styles-or-sharedStrings-parts.xlsx"))
  expect_identical(dim(out), c(11L, 3L))
  expect_named(out, c("Language", "Age", "Churn probability"))
  expect_identical(out$Language[1:3], c("german", "german", "turkish"))
  expect_identical(out$Age[1:3], c(73, 71, 72))
  expect_true(is.numeric(out[["Churn probability"]]))
  # No styles part means nothing can be a date.
  expect_false(any(vapply(out, inherits, logical(1), "Date")))
})

test_that("a workbook using another relationships prefix reads its cells", {
  # nonstandard-xml-ns-prefix.xlsx binds the relationships namespace to "ns",
  # so its <sheet> elements carry ns:id. This is what vendored patch 0002 is
  # for, and reaching the cells is a stronger check than listing the sheet.
  out <- read_xlsx(path_to("nonstandard-xml-ns-prefix.xlsx"))
  expect_identical(out$a, c(1, 2))
  expect_identical(out$b, c(3, 4))
})

test_that("non-ASCII worksheet names address the right worksheet", {
  path <- path_to("utf8-sheet-names.xlsx")
  sheets <- xlsx_sheets(path)
  expect_identical(sheets, c("µ", "∂"))

  # By name and by position must agree, which is the thing that breaks if a
  # name is mangled on the way into the native layer.
  for (i in seq_along(sheets)) {
    expect_identical(read_xlsx(path, i), read_xlsx(path, sheets[i]))
  }
  expect_identical(read_xlsx(path, "µ")$x, 1)
})

test_that("every worksheet of every fixture reads without error", {
  # The manifest is the list of what the package claims to handle. Walking it
  # means a fixture added without its own test still has to read, not merely
  # open -- which is what test-linking.R already covers.
  manifest <- read.delim(path_to("MANIFEST.tsv"), stringsAsFactors = FALSE)
  expect_gt(nrow(manifest), 0L)

  for (file in manifest$file) {
    path <- path_to(file)
    for (sheet in seq_along(xlsx_sheets(path))) {
      expect_s3_class(read_xlsx(path, sheet), "data.frame")
      expect_s3_class(xlsx_cells(path, sheet), "data.frame")
    }
  }
})
