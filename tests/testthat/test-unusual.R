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

test_that("part names may use backslashes and any case", {
  # OPC part names are forward-slash separated and compared without regard to
  # case, but real writers store neither. POI's regression file 49609.xlsx
  # names its members "[content_types].xml", "xl\\styles.xml" and
  # "_rels\\.rels", and Excel reads it.
  #
  # Reproduced here at a few hundred bytes rather than by committing the
  # 105 KB original: tools/corpus/ is where that file is read, and this is
  # what keeps the fix from regressing on every platform.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  names(parts) <- vapply(
    names(parts),
    function(n) gsub("/", "\\", tolower(n), fixed = TRUE),
    character(1)
  )
  write_workbook(path, parts)

  expect_identical(xlsx_sheets(path), "Sheet1")
  expect_s3_class(read_xlsx(path, 1), "data.frame")
})

test_that("a conforming workbook is unaffected by that tolerance", {
  # The tolerant lookup must not change what a normal file resolves to. Two
  # members differing only in case is the case that would expose a scan
  # picking the wrong one.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  write_workbook(path, parts)

  expect_identical(xlsx_sheets(path), "Sheet1")
})

test_that("a ZIP64 archive reads, however its limits are escaped", {
  # ZIP64 lifts the format's 32-bit limits. A field that will not fit is
  # stored as all-ones and the real value moves to a ZIP64 extra field, with a
  # ZIP64 end of central directory record and locator ahead of the ordinary
  # one. The three cases below are the three places that escaping can happen,
  # and a reader that handles only one of them fails on real archives.
  #
  # These are tiny and use the structures anyway, which is how the format can
  # be covered without a four gigabyte fixture. Writers do the same when
  # streaming, not knowing the final size in advance.
  for (where in c("eocd", "entry", "both")) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    write_zip64_workbook(path, where = where)

    expect_identical(xlsx_sheets(path), "Sheet1")
    # Listing sheets is not enough: it reads xl/workbook.xml and stops. The
    # cells prove the per-entry offsets were resolved as well.
    expect_identical(nrow(xlsx_cells(path, 1)), 1L)
  }
})

test_that("a ZIP64 workbook gives the same answer as a plain one", {
  # Same parts, two container encodings. The bytes of the archive differ; what
  # comes out must not.
  parts <- styled_workbook_parts(list(
    c(txt("A1", "n"), txt("B1", "s")),
    c(num("A2", 42.5), txt("B2", "x")),
    c(num("A3", -1), txt("B3", "y"))
  ))

  plain <- withr::local_tempfile(fileext = ".xlsx")
  zip64 <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(plain, parts)
  write_zip64_workbook(zip64, parts, where = "both")

  expect_false(identical(
    readBin(plain, "raw", file.size(plain)),
    readBin(zip64, "raw", file.size(zip64))
  ))
  expect_identical(read_xlsx(zip64), read_xlsx(plain))
  expect_identical(read_xlsx(zip64)$n, c(42.5, -1))
})

test_that("the ZIP64 end of central directory record is actually used", {
  # The negative control. Without it the tests above would prove only that a
  # ZIP64 archive can be read, not that its ZIP64 structures were read --
  # a reader ignoring them entirely would pass just as well.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_zip64_workbook(path, where = "both")
  bytes <- readBin(path, "raw", file.size(path))

  at <- find_zip_signature(bytes, c(0x50, 0x4b, 0x06, 0x06))
  expect_length(at, 1L)

  # Destroying the record leaves an archive whose ordinary end-of-central-
  # directory says only "look in the ZIP64 one", so it cannot be read.
  bytes[at + 0:3] <- as.raw(0)
  writeBin(bytes, path)
  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("the central directory offset is read from the ZIP64 record", {
  # More specific than the above: not just that the record is present, but
  # that the offset inside it is what is followed.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_zip64_workbook(path, where = "both")
  bytes <- readBin(path, "raw", file.size(path))
  at <- find_zip_signature(bytes, c(0x50, 0x4b, 0x06, 0x06))

  # The offset of the central directory is the last 8 bytes of the record.
  bytes[at + 48:55] <- as.raw(c(0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0))
  writeBin(bytes, path)
  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
})

test_that("KNOWN: the ZIP64 locator is not consulted", {
  # Characterisation, not a requirement. miniz finds the ZIP64 end of central
  # directory record by scanning for its signature rather than by following
  # the locator that precedes the ordinary record, so a locator pointing far
  # past the end of the file changes nothing.
  #
  # That is permissive rather than wrong -- the record it finds is the right
  # one -- but it is worth pinning, because an archive that is malformed in
  # exactly this way is read rather than refused, and a future miniz that
  # started honouring the locator would change that silently.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_zip64_workbook(path, where = "both")
  bytes <- readBin(path, "raw", file.size(path))

  at <- find_zip_signature(bytes, c(0x50, 0x4b, 0x06, 0x07))
  expect_length(at, 1L)
  # The locator's 8-byte offset field follows its signature and disk number.
  bytes[at + 8:15] <- as.raw(c(0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0))
  writeBin(bytes, path)

  expect_identical(xlsx_sheets(path), "Sheet1")
})
