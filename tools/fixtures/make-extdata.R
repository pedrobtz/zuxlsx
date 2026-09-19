#!/usr/bin/env Rscript
# Generates inst/extdata/two-sheets.xlsx, the workbook every example uses.
#
#   Rscript tools/fixtures/make-extdata.R            write the file
#   Rscript tools/fixtures/make-extdata.R --check    verify it is reproducible
#
# The output is committed. This script exists so the bytes can be re-derived
# and checked rather than taken on trust, which is the same bargain
# tools/vendor makes for the vendored source.
#
# The workbook is deliberately small and deliberately varied: it has two
# worksheets so that `sheet =` means something in an example, and its first
# sheet holds one column of each type read_xlsx() infers, so the examples show
# the type inference rather than a block of numbers.

args <- commandArgs(trailingOnly = TRUE)
root <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])), "..", ".."))
source(file.path(root, "tools", "fixtures", "zip.R"))

ns <- 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
rns <- 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

inline <- function(ref, text) {
  paste0('<c r="', ref, '" t="inlineStr"><is><t>', text, "</t></is></c>")
}
number <- function(ref, v, style = NULL) {
  paste0(
    '<c r="', ref, '"', if (is.null(style)) "" else paste0(' s="', style, '"'),
    "><v>", v, "</v></c>"
  )
}
boolean <- function(ref, v) paste0('<c r="', ref, '" t="b"><v>', v, "</v></c>")

sheet <- function(rows) {
  paste0(
    '<?xml version="1.0" encoding="UTF-8"?><worksheet ', ns, "><sheetData>",
    paste0(
      "<row r=\"", seq_along(rows), "\">",
      vapply(rows, paste0, character(1), collapse = ""),
      "</row>",
      collapse = ""
    ),
    "</sheetData></worksheet>"
  )
}

# Serial 45324 is 2024-02-02 under the 1900 system this workbook uses.
readings <- sheet(list(
  c(inline("A1", "station"), inline("B1", "reading"),
    inline("C1", "checked"), inline("D1", "taken")),
  c(inline("A2", "north"), number("B2", 12.5), boolean("C2", 1), number("D2", 45324, 1)),
  c(inline("A3", "south"), number("B3", 9.75), boolean("C3", 0), number("D3", 45325, 1)),
  c(inline("A4", "east"), number("B4", 14.25), boolean("C4", 1), number("D4", 45326, 1))
))
notes <- sheet(list(
  c(inline("A1", "note")),
  c(inline("A2", "calibrated in January")),
  c(inline("A3", "µg/m³"))
))

parts <- list(
  "[Content_Types].xml" = paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
    "</Types>"
  ),
  "_rels/.rels" = paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>',
    "</Relationships>"
  ),
  "xl/workbook.xml" = paste0(
    '<?xml version="1.0" encoding="UTF-8"?><workbook ', ns, " ", rns, ">",
    '<sheets><sheet name="readings" sheetId="1" r:id="rId1"/>',
    '<sheet name="notes" sheetId="2" r:id="rId2"/></sheets></workbook>'
  ),
  "xl/_rels/workbook.xml.rels" = paste0(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>',
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>',
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
    "</Relationships>"
  ),
  # Style 1 is numFmtId 14, the built-in short date, which is what makes
  # column D a Date rather than the number it is stored as.
  "xl/styles.xml" = paste0(
    '<?xml version="1.0" encoding="UTF-8"?><styleSheet ', ns, ">",
    '<cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs>',
    "</styleSheet>"
  ),
  "xl/worksheets/sheet1.xml" = readings,
  "xl/worksheets/sheet2.xml" = notes
)

target <- file.path(root, "inst", "extdata", "two-sheets.xlsx")
dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)

if (identical(args[1], "--check")) {
  if (!file.exists(target)) {
    stop("missing: ", target, ". Run without --check to create it.", call. = FALSE)
  }
  tmp <- tempfile(fileext = ".xlsx")
  write_xlsx_parts(tmp, parts)
  want <- readBin(target, "raw", file.size(target))
  got <- readBin(tmp, "raw", file.size(tmp))
  if (!identical(want, got)) {
    stop(
      "inst/extdata/two-sheets.xlsx does not match what this script produces.\n",
      "  committed: ", length(want), " bytes\n",
      "  generated: ", length(got), " bytes",
      call. = FALSE
    )
  }
  cat("ok  inst/extdata/two-sheets.xlsx is reproducible (", length(want), " bytes)\n", sep = "")
} else {
  write_xlsx_parts(target, parts)
  cat("wrote ", target, " (", file.size(target), " bytes)\n", sep = "")
}
