#' Read a worksheet in chunks
#'
#' Reads a worksheet a piece at a time, passing each piece to a function rather
#' than returning the whole thing. This is the low-level streaming reader: use
#' it when a worksheet is too large to hold, or when the answer can be found
#' without reading all of it.
#'
#' `callback` is called with a data frame of cells in the shape [xlsx_cells()]
#' returns. Returning `FALSE` from it stops the read, leaving the rest of the
#' worksheet unparsed; any other value continues.
#'
#' A chunk never splits a row, so a callback can rely on seeing every cell of
#' a row together. `chunk_size` is therefore a lower bound rather than an exact
#' count: a chunk ends at the first row boundary at or after it.
#'
#' @param path Path to an `.xlsx` file.
#' @param sheet The worksheet to read: either its name, or its position in the
#'   workbook.
#' @param callback A function of one argument, called with each chunk of cells.
#'   Return `FALSE` to stop reading.
#' @param chunk_size The least number of cells to gather before calling
#'   `callback`.
#'
#' @return `TRUE` if `callback` stopped the read, `FALSE` if the worksheet was
#'   read to the end. Returned invisibly.
#' @export
#' @seealso [xlsx_cells()], which reads a whole worksheet at once, and
#'   [read_xlsx()], which builds columns from it.
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#'
#' # Count the cells of each type without holding the worksheet.
#' totals <- integer(0)
#' xlsx_read_cells(path, 1, function(cells) {
#'   totals <<- c(totals, table(cells$type))
#' })
#'
#' # Stop as soon as something is found. The rest of the sheet is not parsed.
#' first <- NULL
#' xlsx_read_cells(path, 1, function(cells) {
#'   hit <- cells[cells$type == "date", ]
#'   if (nrow(hit) > 0) {
#'     first <<- hit[1, ]
#'     FALSE
#'   }
#' })
#' first
xlsx_read_cells <- function(path, sheet = 1, callback, chunk_size = 10000L) {
  path <- check_path(path)
  sheet <- resolve_sheet(path, sheet)
  if (!is.function(callback)) {
    zuxlsx_stop("zuxlsx_input_error", "`callback` must be a function.")
  }
  if (!is.numeric(chunk_size) || length(chunk_size) != 1L ||
      is.na(chunk_size) || chunk_size < 1) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`chunk_size` must be a single positive number."
    )
  }

  # The callback is wrapped rather than passed through, so that the native
  # layer hands R vectors to one place and the data frame is assembled here,
  # where the column names and the type labels already live.
  wrapped <- function(parts) {
    cells <- data.frame(
      row = parts[[1L]],
      col = parts[[2L]],
      type = factor(CELL_TYPES[parts[[3L]] + 1L], levels = CELL_TYPES),
      value = parts[[4L]],
      number = parts[[5L]],
      stringsAsFactors = FALSE
    )
    attr(cells, "date1904") <- parts[[6L]]
    callback(cells)
  }

  stopped <- zuxlsx_unwrap(
    .Call(
      C_xlsx_read_cells, path, sheet, wrapped, environment(),
      as.integer(chunk_size)
    ),
    path = path
  )
  invisible(isTRUE(stopped))
}
