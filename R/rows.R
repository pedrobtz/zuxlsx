#' Read a worksheet as rows
#'
#' Returns a worksheet row by row, as the text of each cell, without inferring
#' a type for any column. This is the row-oriented counterpart to
#' [xlsx_cells()], and is the shape to reach for when a worksheet is not
#' rectangular enough for [read_xlsx()] -- a report with stacked blocks, or a
#' file whose header is several rows deep.
#'
#' @return A list with one character vector per row, from row 1 of the
#'   worksheet to the last row holding a cell, so the nth element is row n.
#'   Every vector is as long as the widest row, so the nth element of each is
#'   column n. Blank cells, and rows with none, are `NA`.
#' @inheritParams xlsx_cells
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
xlsx_rows <- function(path, sheet = 1, password = NULL) {
  cells <- xlsx_cells(path, sheet, password = password)
  if (nrow(cells) == 0L) {
    return(list())
  }

  # Rows run from 1, as columns do, so that rows[[n]][m] is the cell in row n,
  # column m: an omitted row stays a row, and so do leading empty ones. One
  # matrix filled by position keeps this linear in the number of cells.
  value <- cells$value
  value[cells$type == "blank"] <- NA_character_
  grid <- matrix(NA_character_, nrow = max(cells$row), ncol = max(cells$col))
  grid[cbind(cells$row, cells$col)] <- value
  lapply(seq_len(nrow(grid)), function(i) grid[i, ])
}
