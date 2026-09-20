# Generates mutants for tools/fuzz/run. Not used directly.
#
# The seeds are deliberately small and varied rather than numerous: a mutation
# of a 4 KB workbook reaches the interesting code as often as one of a 300 KB
# workbook and is far quicker to read, and a finding in a small file is a
# finding somebody can actually look at.
source("tools/fuzz/mutate.R")

args <- commandArgs(trailingOnly = TRUE)
count <- as.integer(args[1])
work <- args[2]
glob <- if (length(args) >= 3 && nzchar(args[3])) args[3] else NULL

seeds <- if (!is.null(glob)) {
  Sys.glob(glob)
} else {
  c(
    "inst/extdata/two-sheets.xlsx",
    Sys.glob("tests/testthat/sheets/*.xlsx"),
    # A handful of real ones, chosen small: strict OOXML, shared strings,
    # styles, and a workbook with no optional parts at all.
    "tools/corpus/files/poi/SimpleStrict.xlsx",
    "tools/corpus/files/poi/59021.xlsx",
    "tools/corpus/files/poi/sample.strict.xlsx"
  )
}
seeds <- seeds[file.exists(seeds)]
if (length(seeds) == 0L) {
  stop("no seed workbooks found", call. = FALSE)
}

log <- vector("list", count)
for (i in seq_len(count)) {
  seed <- seeds[[((i - 1L) %% length(seeds)) + 1L]]
  out <- file.path(work, sprintf("mutant-%05d.xlsx", i))
  log[[i]] <- tryCatch(
    mutate_workbook(seed, out, i),
    error = function(e) NULL
  )
}
written <- Filter(Negate(is.null), log)
utils::write.table(
  do.call(rbind, written), file.path(work, "mutants.tsv"),
  sep = "\t", row.names = FALSE, quote = FALSE
)
cat("    ", length(written), " mutants from ", length(seeds), " seeds\n", sep = "")
