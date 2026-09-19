# Reads every file of the external corpus and reports what happened.
#
# Run through tools/corpus/run, not directly. Writes a TSV of one row per
# file to stdout: name, outcome, detail.
#
# Outcome is "ok" when every worksheet reads, or the condition class when one
# does not. Errors are not failures in themselves -- the corpus deliberately
# contains truncated archives, fuzzer output and files that are not workbooks
# at all -- so the run compares outcomes against a committed baseline and
# reports what *changed*.
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
    return(c(sheets$cls, "xlsx_sheets"))
  }
  for (i in seq_along(sheets)) {
    got <- tryCatch(
      {
        zuxlsx::read_xlsx(path, i)
        NULL
      },
      condition = function(e) structure(list(cls = class(e)[1]), class = "zfail")
    )
    if (inherits(got, "zfail")) {
      return(c(got$cls, paste0("read_xlsx sheet ", i)))
    }
  }
  c("ok", paste(length(sheets), "sheets"))
}

files <- sort(list.files(root, pattern = "[.]xls[xb]$", recursive = TRUE))
con <- stdout()
writeLines("file\toutcome\tdetail", con)
for (rel in files) {
  res <- outcome_of(file.path(root, rel))
  writeLines(paste(rel, res[1], res[2], sep = "\t"), con)
  flush(con)
}
