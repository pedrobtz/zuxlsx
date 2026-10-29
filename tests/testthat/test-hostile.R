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

  # Not expanded, and not read either: no part of a workbook carries a
  # DOCTYPE, so one is refused outright (#47). It used to come back as the
  # literal reference "&d;".
  expect_error(xlsx_sheets(path), class = "zuxlsx_xml_error")
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

  cond <- tryCatch(xlsx_sheets(path), error = identity)
  expect_s3_class(cond, "zuxlsx_xml_error")
  expect_false(grepl("CANARY", conditionMessage(cond), fixed = TRUE))
})

test_that("a DOCTYPE is refused in every part, not only the workbook", {
  # An internal subset declaring an entity, then a reference to it. Under
  # zuxml's XML_GE 0 the entity is not expanded, so before #47 the reference
  # reached the cell as the literal text "&e;".
  doctype <- '<!DOCTYPE x [<!ENTITY e "expanded">]>'
  ns <- 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
  part_with_doctype <- function(name, body) {
    path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = parent.frame())
    parts <- styled_workbook_parts(c('<c r="A1" t="s"><v>0</v></c>', txt("B1", "&e;")))
    parts[["xl/sharedStrings.xml"]] <- paste0(
      '<?xml version="1.0"?><sst ', ns, "><si><t>zero</t></si></sst>"
    )
    parts[["xl/_rels/workbook.xml.rels"]] <- sub(
      "</Relationships>",
      paste0(
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/',
        'officeDocument/2006/relationships/sharedStrings" ',
        'Target="sharedStrings.xml"/></Relationships>'
      ),
      parts[["xl/_rels/workbook.xml.rels"]],
      fixed = TRUE
    )
    parts[[name]] <- sub("?>", paste0("?>", doctype), parts[[name]], fixed = TRUE)
    write_workbook(path, parts)
    path
  }
  for (name in c("xl/worksheets/sheet1.xml", "xl/sharedStrings.xml",
                 "xl/styles.xml", "xl/_rels/workbook.xml.rels",
                 "[Content_Types].xml")) {
    path <- part_with_doctype(name)
    expect_error(xlsx_cells(path), class = "zuxlsx_xml_error", info = name)
  }
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

test_that("a corrupt CRC-32 on the workbook part is a ZIP error", {
  # Was a pinned KNOWN GAP: miniz's extract-iterator path does not check the
  # checksum, so a member corrupted in transit parsed as if intact. Listing
  # now validates the parts it reads, and every reader lists first.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  entries[[3L]] <- zip_entry(
    "xl/workbook.xml",
    workbook_xml("CRCBAD"),
    declared_crc = as.raw(c(0L, 0L, 0L, 0L))
  )
  write_zip(path, entries)

  expect_error(xlsx_sheets(path), class = "zuxlsx_zip_error")
  expect_error(xlsx_read(path), class = "zuxlsx_zip_error")
  expect_identical(.Call(C_xlsx_sheets, normalizePath(path), NULL)$value$part,
                   "xl/workbook.xml")
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

test_that("a cell reference past XFD1048576 is refused before it is padded to", {
  # Without a bound, one cell at A99999999999 had the reader pad a hundred
  # billion rows; a long column reference also wrapped size_t.
  refs <- c("A1048577", "XFE1", "A99999999999", "ZZZZZZZZZZZZ1",
            "A18446744073709551617", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1")
  for (ref in refs) {
    path <- withr::local_tempfile(fileext = ".xlsx")
    write_workbook(path, styled_workbook_parts(c(num("A1", 1), num(ref, 5))))
    elapsed <- system.time({
      expect_error(xlsx_read(path), class = "zuxlsx_ooxml_error", info = ref)
      expect_error(xlsx_cells(path), class = "zuxlsx_ooxml_error", info = ref)
      expect_error(xlsx_rows(path), class = "zuxlsx_ooxml_error", info = ref)
      expect_error(
        xlsx_stream_cells(path, 1, function(cells) NULL),
        class = "zuxlsx_ooxml_error", info = ref
      )
    })[["elapsed"]]
    expect_lt(elapsed, 10)
  }

  # The last cell itself is within the grid.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(num("XFD1", 5)))
  cells <- xlsx_cells(path)
  expect_identical(max(cells$col), 16384)
})

test_that("a reference that names no position is read in document order", {
  # Not an error: r= is optional, and a cell without a usable one takes the
  # next position, as Excel does.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(c(
    '<c r="?"><v>1</v></c>', '<c><v>2</v></c>'
  )))
  expect_identical(xlsx_cells(path)$number, c(1, 2))
})

test_that("a well-formed but deeply nested worksheet or workbook is read", {
  skip_if_light()
  # Expat's parser is iterative, so depth costs memory rather than stack. The
  # nesting is inside a real root element: two roots would be refused for
  # that alone, whatever the depth.
  deep <- function(n) {
    paste0(paste0(rep("<x>", n), collapse = ""), paste0(rep("</x>", n), collapse = ""))
  }
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- sub(
    "<sheets>", paste0(deep(100000L), "<sheets>"), parts[["xl/workbook.xml"]],
    fixed = TRUE
  )
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<sheetData>", deep(100000L),
    '<row r="1"><c r="A1"><v>7</v></c></row></sheetData></worksheet>'
  )
  write_workbook(path, parts)

  expect_identical(xlsx_sheets(path), "Sheet1")
  expect_identical(xlsx_cells(path)$number, 7)
})

test_that("a shared-string index that does not resolve is an error, not a blank", {
  shared <- paste0(
    '<?xml version="1.0"?>',
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<si><t>zero</t></si><si/><si><t>two</t></si></sst>"
  )
  read_index <- function(v, with_table = TRUE) {
    path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = parent.frame())
    parts <- styled_workbook_parts(paste0('<c r="A1" t="s"><v>', v, "</v></c>"))
    if (with_table) {
      parts[["xl/sharedStrings.xml"]] <- shared
      parts[["xl/_rels/workbook.xml.rels"]] <- sub(
        "</Relationships>",
        paste0(
          '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/',
          'officeDocument/2006/relationships/sharedStrings" ',
          'Target="sharedStrings.xml"/></Relationships>'
        ),
        parts[["xl/_rels/workbook.xml.rels"]],
        fixed = TRUE
      )
    }
    write_workbook(path, parts)
    xlsx_cells(path)
  }

  expect_identical(read_index("0")$value, "zero")
  # XML Schema allows whitespace around an integer, and real writers use it
  # (POI's bug69769.xlsx has <v>2 </v>).
  expect_identical(read_index(" 0 ")$value, "zero")
  # An empty <si/> is in the table: a blank cell, not a missing string --
  # and the entry after it is still at its own index. xlsxio used to skip
  # <si/>, which moved every later string up by one.
  expect_identical(as.character(read_index("1")$type), "blank")
  expect_identical(read_index("2")$value, "two")
  for (v in c("3", "-1", "x")) {
    expect_error(read_index(v), class = "zuxlsx_ooxml_error", info = v)
  }
  # An empty <v/> names no index at all, and is a blank cell.
  expect_identical(as.character(read_index("")$type), "blank")
  expect_error(read_index("0", with_table = FALSE), class = "zuxlsx_ooxml_error")

  # A table whose elements carry a namespace prefix is the same table.
  shared <- paste0(
    '<?xml version="1.0"?>',
    '<x:sst xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<x:si><x:t>zero</x:t></x:si></x:sst>"
  )
  expect_identical(read_index("0")$value, "zero")
})

test_that("a worksheet whose CRC-32 does not match is a ZIP error", {
  # A worksheet's checksum is checked when it has been read to its end.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  sheet <- which(names(parts) == "xl/worksheets/sheet1.xml")
  entries[[sheet]] <- zip_entry(
    "xl/worksheets/sheet1.xml",
    parts[["xl/worksheets/sheet1.xml"]],
    declared_crc = as.raw(c(0L, 0L, 0L, 0L))
  )
  write_zip(path, entries)

  expect_identical(xlsx_sheets(path), "Sheet1")
  expect_error(xlsx_cells(path), class = "zuxlsx_zip_error")
  expect_error(xlsx_read(path), class = "zuxlsx_zip_error")
})

test_that("a compression bomb is streamed or refused, never inflated whole", {
  skip_if_light()
  # 50 MB of whitespace inside <sheetData> deflates to about 50 KB. The
  # worksheet is parsed as it inflates, so memory does not follow the
  # uncompressed size; and a member that inflates past the size it declares
  # is cut off there, which ends the worksheet early -- an error.
  bomb <- charToRaw(paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<sheetData>", strrep(" ", 5e7),
    '<row r="1"><c r="A1"><v>7</v></c></row></sheetData></worksheet>'
  ))

  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(n) zip_entry(n, parts[[n]]))
  sheet <- which(names(parts) == "xl/worksheets/sheet1.xml")
  entries[[sheet]] <- zip_entry(
    "xl/worksheets/sheet1.xml", bomb,
    declared_size = 2000, declared_crc = as.raw(c(0, 0, 0, 0)),
    deflate = TRUE
  )
  write_zip(path, entries)
  expect_lt(file.size(path), 1e6)

  elapsed <- system.time(
    cond <- tryCatch(xlsx_cells(path), error = identity)
  )[["elapsed"]]
  expect_true(inherits(cond, "zuxlsx_zip_error") ||
                inherits(cond, "zuxlsx_xml_error"))
  expect_lt(elapsed, 10)

  # Declared honestly, it is just a large worksheet, read as one. The CRC is
  # left wrong -- computing it in R takes minutes -- so it reads to the end
  # and is then refused on the checksum, which is the point: every byte was
  # streamed through and none was held.
  entries[[sheet]] <- zip_entry(
    "xl/worksheets/sheet1.xml", bomb,
    declared_crc = as.raw(c(0, 0, 0, 0)), deflate = TRUE
  )
  write_zip(path, entries)
  elapsed <- system.time(
    expect_error(xlsx_cells(path), class = "zuxlsx_zip_error")
  )[["elapsed"]]
  expect_lt(elapsed, 30)
})

test_that("a deflated worksheet reads like a stored one", {
  # The archive tests otherwise only build stored members; this is the
  # DEFLATE path the real world uses, through the same writer.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- grid_workbook(3L, 3L)
  write_zip(path, lapply(names(parts), function(n) {
    zip_entry(n, parts[[n]], deflate = TRUE)
  }))
  stored <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(stored, parts)
  expect_identical(xlsx_read(path, col_names = FALSE),
                   xlsx_read(stored, col_names = FALSE))
})

test_that("a long read can be interrupted, and leaves nothing open", {
  # The reader checks for an interrupt every thousand rows. An elapsed-time
  # limit is signalled at the same check, so it stands in for Ctrl-C here
  # (#42). The cleanup closes the reader as the error unwinds; that nothing
  # leaked is for valgrind and ASan to show, and a clean read afterwards is
  # what R can see.
  skip_on_cran()
  skip_if_light()
  n <- 600000L
  sheet <- charToRaw(paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    "<sheetData>",
    paste0('<row r="', seq_len(n), '"><c r="A', seq_len(n), '"><v>',
           seq_len(n), "</v></c></row>", collapse = ""),
    "</sheetData></worksheet>"
  ))
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  entries <- lapply(names(parts), function(nm) zip_entry(nm, parts[[nm]]))
  at <- which(names(parts) == "xl/worksheets/sheet1.xml")
  # CRC left wrong (computing it in R is slow): the read is stopped long
  # before the end, where the checksum would be compared.
  entries[[at]] <- zip_entry("xl/worksheets/sheet1.xml", sheet,
                             declared_crc = as.raw(c(0, 0, 0, 0)), deflate = TRUE)
  write_zip(path, entries)

  for (reader in list(
    function() xlsx_read(path),
    function() xlsx_cells(path),
    function() xlsx_stream_cells(path, 1, function(cells) NULL)
  )) {
    elapsed <- system.time(expect_error(local({
      setTimeLimit(elapsed = 0.1, transient = TRUE)
      on.exit(setTimeLimit(elapsed = Inf))
      reader()
    }), "time limit"))[["elapsed"]]
    expect_lt(elapsed, 5)
  }

  small <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(small, grid_workbook(3L, 3L))
  expect_identical(dim(xlsx_read(small, col_names = FALSE)), c(3L, 3L))
})
