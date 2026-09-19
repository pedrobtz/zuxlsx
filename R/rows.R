#' Read a worksheet as rows
#'
#' Returns a worksheet row by row, as the text of each cell, without inferring
#' a type for any column. This is the row-oriented counterpart to
#' [xlsx_cells()], and is the shape to reach for when a worksheet is not
#' rectangular enough for [read_xlsx()] -- a report with stacked blocks, or a
#' file whose header is several rows deep.
#'
#' @param path Path to an `.xlsx` file.
#' @param sheet The worksheet to read: either its name, or its position in the
#'   workbook.
#'
#' @return A list with one character vector per row, from the first row of the
#'   worksheet to the last. Every vector is as long as the widest row, so the
#'   nth element of each is the nth column. Blank cells are `NA`.
#' @export
#' @seealso [xlsx_cells()] for typed cells, [read_xlsx()] for a data frame.
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#' rows <- xlsx_rows(path)
#'
#' # One character vector per row, every one as wide as the widest, with no
#' # type inference: a number is its text.
#' rows[[1]]
#' rows[[2]]
xlsx_rows <- function(path, sheet = 1) {
  cells <- xlsx_cells(path, sheet)
  if (nrow(cells) == 0L) {
    return(list())
  }

  # Rows are spanned rather than taken from the cells present, for the same
  # reason read_xlsx() spans them: an omitted row has to stay a row.
  rows <- seq.int(min(cells$row), max(cells$row))
  width <- max(cells$col)

  blank <- as.character(cells$type) == "blank"
  value <- cells$value
  value[blank] <- NA_character_

  out <- vector("list", length(rows))
  for (i in seq_along(rows)) {
    in_row <- cells$row == rows[i]
    line <- rep(NA_character_, width)
    line[cells$col[in_row]] <- value[in_row]
    out[[i]] <- line
  }
  out
}
