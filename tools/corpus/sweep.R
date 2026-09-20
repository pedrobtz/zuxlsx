# Reads every file of the external corpus and reports what happened.
#
# Run through tools/corpus/run, not directly. Writes a TSV of one row per
# file to stdout: name, outcome, detail.
#
# Outcome is "ok" when every worksheet reads, or the condition class when one
# does not. Errors are not failures in themselves -- the corpus deliberately
# contains truncated archives, fuzzer output and files that are not workbooks
# at all -- so the run compares against a committed baseline and reports what
# *changed*.
#
# The cell count is recorded as well as the outcome, and that is not
# decoration. Tracking only "did it raise a condition" missed a real defect
# for as long as the corpus existed: strict OOXML workbooks listed their
# worksheets and then read as completely empty, which is silent data loss and
# which "ok" described perfectly. A count makes it visible, and makes a fix
# visible too -- four files went from 0 cells to their real contents and
# nothing in the old baseline moved at all.
#
# Each row is flushed as it is produced, so a crash leaves the file that
# caused it as the last line of output rather than losing the whole run.

suppressMessages(pkgload::load_all(quiet = TRUE))

args <- commandArgs(trailingOnly = TRUE)
root <- args[1]

outcome_of <- function(path) {
  sheets <- tryCatch(
    zuxlsx::xlsx_sheets(path),
    condition = function(e) structure(list(cls = class(e)[1]), class = "zfail")
  )
  if (inherits(sheets, "zfail")) {
    return(c(sheets$cls, "0", "0"))
  }
  cells <- 0
  for (i in seq_along(sheets)) {
    got <- tryCatch(
      nrow(zuxlsx::xlsx_cells(path, i)),
      condition = function(e) structure(list(cls = class(e)[1]), class = "zfail")
    )
    if (inherits(got, "zfail")) {
      return(c(got$cls, as.character(length(sheets)), as.character(cells)))
    }
    cells <- cells + got
    read <- tryCatch(
      {
        zuxlsx::read_xlsx(path, i)
        NULL
      },
      condition = function(e) structure(list(cls = class(e)[1]), class = "zfail")
    )
    if (inherits(read, "zfail")) {
      return(c(read$cls, as.character(length(sheets)), as.character(cells)))
    }
  }
  c("ok", as.character(length(sheets)), as.character(cells))
}

files <- sort(list.files(root, pattern = "[.]xls[xb]$", recursive = TRUE))
con <- stdout()
writeLines("file\toutcome\tsheets\tcells", con)
for (rel in files) {
  res <- outcome_of(file.path(root, rel))
  writeLines(paste(rel, res[1], res[2], res[3], sep = "\t"), con)
  flush(con)
}
