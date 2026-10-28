# The cell type codes C_xlsx_cells returns, indexed by the ZU_CELL_* enum in
# src/zuxlsx.c. Kept in one place; test-cells.R checks the two agree.
CELL_TYPES <- c("blank", "number", "string", "boolean", "error", "date")

#' Read the cells of a worksheet
#'
#' Reads a worksheet one cell at a time and returns them in a data frame, one
#' row per cell. This is the low-level reader: it reports what is in each cell
#' without assembling columns or guessing a type for them; [read_xlsx()] does
#' that.
#'
#' @param sheet The worksheet to read: either its name, or its position in the
#'   workbook.
#'
#' @return A data frame with one row per cell and the columns:
#'   \describe{
#'     \item{`row`, `col`}{Position, counting from 1.}
#'     \item{`type`}{One of `"blank"`, `"number"`, `"string"`, `"boolean"`,
#'       `"error"` or `"date"`.}
#'     \item{`value`}{The cell as written, as a string.}
#'     \item{`number`}{The numeric value for `"number"`, `"boolean"` and
#'       `"date"` cells, and `NA` otherwise. A date is its Excel serial
#'       number; it is not converted here, because the epoch is a property of
#'       the workbook rather than of the cell. A date written as ISO 8601 text
#'       (`t="d"`) is given the serial an Excel number would have; one that
#'       cannot be read as a date is a `"string"`.}
#'   }
#' @inheritParams xlsx_sheets
#' @export
#' @seealso [xlsx_sheets()] to list the worksheets, and [zuxlsx-conditions]
#'   for the errors this can raise.
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#' cells <- xlsx_cells(path)
#' head(cells)
#'
#' # The type is the cell's own, before any column is built from it. A date is
#' # reported as a date and its serial number given unconverted, because the
#' # epoch belongs to the workbook rather than to the cell.
#' table(cells$type)
#' attr(cells, "date1904")
#'
#' # The second worksheet, by name rather than by position.
#' xlsx_cells(path, "notes")
xlsx_cells <- function(path, sheet = 1, password = NULL) {
  path <- check_path(path)
  password <- check_optional_password(password)
  sheet <- resolve_sheet(path, sheet, password)

  # Unwrapped here rather than inside cells_frame()'s argument, where lazy
  # evaluation would make data.frame() the call an error reports.
  parts <- zuxlsx_unwrap(
    .Call(C_xlsx_cells, path, sheet, password),
    path = path
  )
  cells_frame(parts)
}

# The data frame xlsx_cells() returns and xlsx_read_cells() hands to its
# callback, from the six vectors the native layer builds.
cells_frame <- function(parts) {
  out <- data.frame(
    row = parts[[1L]],
    col = parts[[2L]],
    type = factor(CELL_TYPES[parts[[3L]] + 1L], levels = CELL_TYPES),
    value = parts[[4L]],
    number = parts[[5L]],
    stringsAsFactors = FALSE
  )
  # The date epoch is a property of the workbook, not of any cell, so it rides
  # along as an attribute rather than as a column. read_xlsx() needs it to turn
  # a serial number into a date; a caller working with cells directly needs it
  # for the same reason.
  attr(out, "date1904") <- parts[[6L]]
  out
}
