# Adversarial workbooks: the `hostile/` category of design section 17.4, and
# the defenses design section 16 asks for.
#
# An .xlsx is an untrusted ZIP full of untrusted XML. Most of what follows
# passes today because of how Expat and miniz behave by default rather than
# because zuxlsx asks them to. That is exactly why it is pinned here: nothing
# in the build would otherwise notice if an xlsxio bump, or a change to how
# the parser is created, quietly turned one of these back on.

test_that("internal entities are not expanded", {
  # The billion-laughs shape. Four levels of ten-fold expansion is harmless in
  # itself; the assertion is that no expansion happens at all, which is what
  # makes the unbounded version a non-issue rather than a denial of service.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    "<!DOCTYPE workbook [",
    '<!ENTITY a "aaaaaaaaaa">',
    '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">',
    '<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">',
    '<!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">',
    "]>",
    '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<sheets><sheet name="&d;" sheetId="1" r:id="rId1"/></sheets></workbook>'
  )
  write_workbook(path, parts)

  sheets <- xlsx_sheets(path)
  # The reference survives verbatim rather than becoming 10000 characters.
  expect_identical(sheets, "&d;")
})

test_that("external entities are not resolved off disk", {
  # If Expat ever resolved these, a workbook could read a file from the
  # machine that opened it and hand the contents back as a sheet name.
  canary <- withr::local_tempfile()
  writeLines("CANARY-LEAKED", canary)

  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<!DOCTYPE workbook [<!ENTITY x SYSTEM "file://', canary, '">]>',
    '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<sheets><sheet name="&x;" sheetId="1" r:id="rId1"/></sheets></workbook>'
  )
  write_workbook(path, parts)

  sheets <- xlsx_sheets(path)
  expect_false(any(grepl("CANARY", sheets, fixed = TRUE)))
  expect_identical(sheets, "&x;")
})

test_that("pathologically nested XML is refused rather than recursed into", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    paste0(rep("<x>", 5000L), collapse = ""),
    paste0(rep("</x>", 5000L), collapse = ""),
    "<workbook/>"
  )
  write_workbook(path, parts)

  expect_error(xlsx_sheets(path), class = "zuxlsx_error")
})

test_that("a duplicated archive member resolves to the first one, always", {
  # Classic ZIP ambiguity: two members with the same name, and different
  # readers disagree about which one wins. Whichever zuxlsx picks, it must
  # pick the same one every time, or a workbook can present one face to a
  # validator and another to the reader.
  first_wins <- function(first, second) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    parts <- workbook_parts()
    entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
    entries[[3L]] <- zip_entry("xl/workbook.xml", workbook_xml(first))
    entries <- c(entries, list(zip_entry("xl/workbook.xml", workbook_xml(second))))
    write_zip(path, entries)
    xlsx_sheets(path)
  }

  expect_identical(first_wins("FIRST", "SECOND"), "FIRST")
  expect_identical(first_wins("SECOND", "FIRST"), "SECOND")
})

test_that("a self-referential relationship does not loop", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- workbook_rels_xml(
    targets = "../xl/workbook.xml"
  )
  write_workbook(path, parts)

  # Listing sheets must terminate. The name comes from workbook.xml, so the
  # cyclic target is simply never followed at this stage.
  expect_identical(xlsx_sheets(path), "Sheet1")
})

test_that("a very large sheet name is handled without a size limit surprise", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  huge <- paste0(rep("z", 200000L), collapse = "")
  parts[["xl/workbook.xml"]] <- workbook_xml(huge)
  write_workbook(path, parts)

  sheets <- xlsx_sheets(path)
  expect_identical(nchar(sheets), 200000L)
})

test_that("a workbook with many sheets is listed completely and in order", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  names_in <- paste0("S", seq_len(2000L))
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- workbook_xml(names_in)
  write_workbook(path, parts)

  expect_identical(xlsx_sheets(path), names_in)
})

test_that("a sheet whose relationship is dangling is still named", {
  # The name lives in workbook.xml, so listing does not depend on the
  # relationship resolving. Pinned because the reading API will need the
  # opposite guarantee, and this is the line between the two.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- workbook_xml("Orphan", rid = "rId99")
  write_workbook(path, parts)

  expect_identical(xlsx_sheets(path), "Orphan")
})

test_that("KNOWN GAP: a corrupt CRC-32 is not detected", {
  # Characterization, not endorsement. miniz's extract-iter path does not
  # verify the checksum, so a member whose bytes were corrupted in transit is
  # parsed as if intact. Design section 16 lists corrupt archives among the
  # things to defend against; nothing does so yet.
  #
  # When CRC validation is added this test SHOULD fail. Replace it with an
  # expect_error(class = "zuxlsx_zip_error") at that point.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  entries[[3L]] <- zip_entry(
    "xl/workbook.xml",
    workbook_xml("CRCBAD"),
    declared_crc = as.raw(c(0L, 0L, 0L, 0L))
  )
  write_zip(path, entries)

  expect_identical(xlsx_sheets(path), "CRCBAD")
})

test_that("members differing only in case or separator still resolve first-first", {
  # Matching part names tolerantly widens what counts as a duplicate: two
  # members that differ only in case, or only in which slash they use, now
  # collide where they did not before. Whichever wins, it must be the earlier
  # one in the central directory, for the same reason as the exact-duplicate
  # case above -- otherwise a workbook can show one part to a validator and
  # another to the reader.
  first_of <- function(first_name, first_sheet, second_name, second_sheet) {
    path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = parent.frame())
    parts <- workbook_parts()
    entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
    entries[[3L]] <- zip_entry(first_name, workbook_xml(first_sheet))
    entries <- c(entries, list(zip_entry(second_name, workbook_xml(second_sheet))))
    write_zip(path, entries)
    xlsx_sheets(path)
  }

  # Same part, different case.
  expect_identical(
    first_of("xl/workbook.xml", "FIRST", "xl/WORKBOOK.xml", "SECOND"),
    "FIRST"
  )
  expect_identical(
    first_of("xl/WORKBOOK.xml", "FIRST", "xl/workbook.xml", "SECOND"),
    "FIRST"
  )
  # Same part, different separator.
  expect_identical(
    first_of("xl/workbook.xml", "FIRST", "xl\\workbook.xml", "SECOND"),
    "FIRST"
  )
  expect_identical(
    first_of("xl\\workbook.xml", "FIRST", "xl/workbook.xml", "SECOND"),
    "FIRST"
  )
})
