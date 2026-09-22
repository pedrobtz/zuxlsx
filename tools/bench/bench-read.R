#!/usr/bin/env Rscript
# Time zuxlsx against readxl and openxlsx2 on a large workbook, with bench.
#
#   Rscript tools/bench/bench-read.R [workbook] [sheet]
#
# workbook: an id from workbooks.tsv, cached by tools/bench/fetch-workbooks, or
# a path to any .xlsx. sheet: an index or a name, for the read task.
# Defaults: xlsx100mb, sheet 1.
#
# Maintainer script: R CMD check never runs it and nothing in the package
# depends on it.

args <- commandArgs(trailingOnly = TRUE)
workbook <- if (length(args) >= 1L) args[[1L]] else "xlsx100mb"
sheet <- if (length(args) >= 2L) args[[2L]] else "1"

path <- if (file.exists(workbook) && !dir.exists(workbook)) {
  normalizePath(workbook)
} else {
  cache <- Sys.getenv("ZUXLSX_BENCH_DIR", "")
  if (!nzchar(cache)) {
    home <- Sys.getenv("XDG_CACHE_HOME", file.path(path.expand("~"), ".cache"))
    cache <- file.path(home, "zuxlsx-bench")
  }
  p <- file.path(cache, paste0(workbook, ".xlsx"))
  if (!file.exists(p)) {
    stop("no workbook at ", p, "\n  run: tools/bench/fetch-workbooks ", workbook,
         call. = FALSE)
  }
  p
}

# Benchmark the working tree, not whatever is installed, when both exist.
if (dir.exists("R") && file.exists("DESCRIPTION")) {
  pkgload::load_all(".", quiet = TRUE)
} else {
  library(zuxlsx)
}

sheets <- zuxlsx::xlsx_sheets(path)
idx <- suppressWarnings(as.integer(sheet))
sheet <- if (!is.na(idx)) sheets[[idx]] else sheet
stopifnot(sheet %in% sheets)

cat(sprintf("%s (%.1f MB), %d sheets, reading %s\n\n",
            basename(path), file.size(path) / 1024^2, length(sheets), sheet))

# Listing worksheets reads only xl/workbook.xml -- except in openxlsx2, whose
# only way in is wb_load(), which inflates and parses the whole package.
cat("-- list worksheets\n")
print(bench::mark(
  zuxlsx = zuxlsx::xlsx_sheets(path),
  readxl = readxl::excel_sheets(path),
  openxlsx2 = openxlsx2::wb_load(path)$get_sheet_names(),
  check = FALSE, iterations = 1L, filter_gc = FALSE
)[c("expression", "median", "mem_alloc")])

# check = FALSE because the three do not agree, and should not: zuxlsx and
# readxl infer column types, openxlsx2 returns its own frame, and comparing
# the values is the corpus sweep's job, not this script's.
cat("\n-- read one sheet\n")
print(bench::mark(
  zuxlsx = zuxlsx::read_xlsx(path, sheet = sheet),
  readxl = readxl::read_xlsx(path, sheet = sheet, .name_repair = "minimal"),
  openxlsx2 = openxlsx2::read_xlsx(path, sheet = sheet),
  check = FALSE, iterations = 1L, filter_gc = FALSE
)[c("expression", "median", "mem_alloc")])

cat("\nmem_alloc is R-level allocation only; the C heap that xlsxio, RapidXML",
    "and\nopenxlsx2 work in does not show up in it. Everything runs in one",
    "process,\nso pass one workbook at a time if memory is what you are chasing.\n")
