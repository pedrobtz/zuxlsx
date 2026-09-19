# Workbooks that are unusual but conforming: the `unusual-valid/` category of
# design section 17.4. These must all succeed. The risk they cover is the
# opposite of the malformed cases -- a reader that is too strict, and rejects
# a file Excel and every other consumer accept.

test_that("archive member order does not matter", {
  # Nothing requires xl/workbook.xml to come first, or the parts to be in any
  # particular order. A reader that depends on the order works by luck.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))

  write_zip(path, rev(entries))
  expect_identical(xlsx_sheets(path), "Sheet1")

  # And with the workbook part moved to the very end.
  write_zip(path, c(entries[-3L], entries[3L]))
  expect_identical(xlsx_sheets(path), "Sheet1")
})

test_that("a relationship target may be spelled unconventionally", {
  for (target in c(
    "worksheets/sheet1.xml",
    "./worksheets/sheet1.xml",
    "/xl/worksheets/sheet1.xml"
  )) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    parts <- workbook_parts()
    parts[["xl/_rels/workbook.xml.rels"]] <- workbook_rels_xml(targets = target)
    write_workbook(path, parts)

    expect_identical(xlsx_sheets(path), "Sheet1")
  }
})

test_that("an end-of-central-directory undercounting entries still opens", {
  # miniz walks what the record claims. Undercounting hides trailing members
  # rather than corrupting the ones it does find, and the workbook part is not
  # one of the hidden ones here.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, entry_count_delta = -1L)

  expect_identical(xlsx_sheets(path), "Sheet1")
})

test_that("sheet names round-trip non-ASCII and awkward characters", {
  # Ampersands and angle brackets have to survive XML escaping; the rest are
  # the encoding cases that a byte-oriented reader gets wrong.
  path <- withr::local_tempfile(fileext = ".xlsx")
  names_in <- c("café", "日本語", "\U0001F600", "a b", "'quoted'")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- workbook_xml(names_in)
  write_workbook(path, parts)

  sheets <- xlsx_sheets(path)
  expect_identical(sheets, names_in)
  expect_true(all(Encoding(sheets[1:3]) == "UTF-8"))
})

test_that("an escaped sheet name is unescaped exactly once", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0" encoding="UTF-8"?><workbook',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<sheets><sheet name="a &amp;amp; b" sheetId="1" r:id="rId1"/></sheets></workbook>'
  )
  write_workbook(path, parts)

  # One level of unescaping, not two: the stored name is the literal
  # "a &amp; b", not "a & b".
  expect_identical(xlsx_sheets(path), "a &amp; b")
})
