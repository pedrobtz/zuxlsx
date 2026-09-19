# The `valid/` category of design section 17.4: conforming workbooks whose
# content must come back exactly. Where test-corpus.R uses real files from
# other projects, these are built here to reach cases the committed corpus
# does not contain -- numeric extremes, formulas, sparse rows, large shared
# string tables and awkward text.

test_that("each numeric form is parsed to the same double R would parse", {
  literals <- c("0", "-1", "2.5", "-3.75E-8", "1e300", "0.1", "123456789012345")
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(c(
    list(txt("A1", "v")),
    lapply(seq_along(literals), function(i) num(paste0("A", i + 1L), literals[i]))
  )))

  expect_identical(read_xlsx(path)$v, as.numeric(literals))
})

test_that("a formula cell reports its cached value", {
  # zuxlsx does not evaluate formulas (section 21); the cached value is the
  # answer, and a numeric one must not be turned into text by the presence of
  # the formula.
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "n"), txt("B1", "s")),
    c(
      '<c r="A2"><f>1+2</f><v>3</v></c>',
      '<c r="B2" t="str"><f>CONCATENATE("a","b")</f><v>ab</v></c>'
    )
  )))

  out <- read_xlsx(path)
  expect_identical(out$n, 3)
  expect_identical(out$s, "ab")
})

test_that("sparse rows keep their spacing", {
  # Rows 2 and 5 hold data; 3 and 4 are absent from the XML entirely. Closing
  # the gap would silently change what row a value came from.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "v"), "</row>",
    '<row r="2">', num("A2", 1), "</row>",
    '<row r="5">', num("A5", 2), "</row>",
    "</sheetData></worksheet>"
  )
  write_workbook(path, parts)

  expect_identical(read_xlsx(path)$v, c(1, NA, NA, 2))
})

test_that("a sparse row keeps its column spacing", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "a"), txt("D1", "d"), "</row>",
    '<row r="2">', num("A2", 1), num("D2", 4), "</row>",
    "</sheetData></worksheet>"
  )
  write_workbook(path, parts)

  out <- read_xlsx(path)
  expect_identical(names(out), c("a", "X2", "X3", "d"))
  expect_identical(out$a, 1)
  expect_identical(out$d, 4)
})

test_that("a large shared string table resolves at both ends", {
  # The shared string list is the one part of the reader that is not streamed
  # (section 10), so it is worth exercising beyond a couple of entries.
  n <- 2000L
  strings <- paste0("s", seq_len(n))
  path <- withr::local_tempfile(fileext = ".xlsx")

  parts <- workbook_parts()
  parts[["xl/_rels/workbook.xml.rels"]] <- sub(
    "</Relationships>",
    paste0(
      '<Relationship Id="rId2"',
      ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"',
      ' Target="sharedStrings.xml"/></Relationships>'
    ),
    parts[["xl/_rels/workbook.xml.rels"]],
    fixed = TRUE
  )
  parts[["xl/sharedStrings.xml"]] <- paste0(
    '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
    ' count="', n, '" uniqueCount="', n, '">',
    paste0("<si><t>", strings, "</t></si>", collapse = ""),
    "</sst>"
  )
  # Reference the first, last and a middle entry.
  picks <- c(1L, n %/% 2L, n)
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "v"), "</row>",
    paste0(
      "<row r=\"", seq_along(picks) + 1L, "\"><c r=\"A", seq_along(picks) + 1L,
      "\" t=\"s\"><v>", picks - 1L, "</v></c></row>",
      collapse = ""
    ),
    "</sheetData></worksheet>"
  )
  write_workbook(path, parts)

  expect_identical(read_xlsx(path)$v, strings[picks])
})

test_that("awkward text survives unchanged", {
  # Astral-plane characters, combining marks, right-to-left text, and the
  # characters XML has to escape.
  values <- c(
    "\U0001F600",
    "é",
    "אבג",
    "a &amp; b",
    "&lt;tag&gt;",
    "line&#10;break",
    "  padded  "
  )
  expected <- c(
    "\U0001F600", "é", "אבג",
    "a & b", "<tag>", "line\nbreak", "  padded  "
  )

  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(c(
    list(txt("A1", "v")),
    lapply(seq_along(values), function(i) txt(paste0("A", i + 1L), values[i]))
  )))

  out <- read_xlsx(path)$v
  expect_identical(out, expected)
  expect_true(all(Encoding(out[1:3]) == "UTF-8"))
})

test_that("a long single string is not truncated", {
  # Excel's own cell limit is 32767 characters; nothing here should impose a
  # smaller one of its own.
  long <- paste0(rep("abcdefghij", 3300L), collapse = "")
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, styled_workbook_parts(list(
    c(txt("A1", "v")), c(txt("A2", long))
  )))

  expect_identical(nchar(read_xlsx(path)$v), 33000L)
})

test_that("worksheets of one workbook are read independently", {
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts(c("one", "two"))
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "v"), '</row><row r="2">', num("A2", 1), "</row>",
    "</sheetData></worksheet>"
  )
  parts[["xl/worksheets/sheet2.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "w"), '</row><row r="2">', txt("A2", "z"), "</row>",
    "</sheetData></worksheet>"
  )
  write_workbook(path, parts)

  expect_identical(read_xlsx(path, 1), data.frame(v = 1))
  expect_identical(read_xlsx(path, 2), data.frame(w = "z", stringsAsFactors = FALSE))
  # Reading one must not disturb the other, in either order.
  expect_identical(read_xlsx(path, 2)$w, "z")
  expect_identical(read_xlsx(path, 1)$v, 1)
})

test_that("a row gap is reconstructed from row numbers, not from padding", {
  # Characterisation of a quirk read_xlsx() deliberately does not rely on:
  # xlsxio pads an omitted row range with a single row however wide it is, so
  # a sheet with data on rows 1, 2 and 5 arrives as rows 1, 2, 4, 5. Every
  # cell carries its true row number, which is what read_xlsx() spans instead.
  path <- withr::local_tempfile(fileext = ".xlsx")
  parts <- workbook_parts()
  parts[["xl/worksheets/sheet1.xml"]] <- paste0(
    '<?xml version="1.0"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
    '<row r="1">', txt("A1", "v"), "</row>",
    '<row r="2">', num("A2", 1), "</row>",
    '<row r="5">', num("A5", 2), "</row>",
    "</sheetData></worksheet>"
  )
  write_workbook(path, parts)

  # What the cell layer reports: one padding row, not two.
  expect_identical(xlsx_cells(path, 1)$row, c(1, 2, 4, 5))
  # What read_xlsx() makes of it: the gap restored to its true width.
  expect_identical(read_xlsx(path)$v, c(1, NA, NA, 2))
})
