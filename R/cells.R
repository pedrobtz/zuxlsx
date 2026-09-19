# The cell type codes C_xlsx_cells returns, in the order design section 13
# lists them. Kept as a constant rather than inlined so that the C enum and
# the R labels cannot drift apart silently.
CELL_TYPES <- c("blank", "number", "string", "boolean", "error", "date")

#' Read the cells of a worksheet
#'
#' Reads a worksheet one cell at a time and returns them in a data frame, one
#' row per cell. This is the low-level reader: it reports what is in each cell
#' without assembling columns or guessing a type for them, which is what
#' `read_xlsx()` will do on top of it.
#'
#' @param path Path to an `.xlsx` file.
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
#'       the workbook rather than of the cell.}
#'   }
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
xlsx_cells <- function(path, sheet = 1) {
  path <- check_path(path)
  sheet <- resolve_sheet(path, sheet)

  cells <- zuxlsx_unwrap(.Call(C_xlsx_cells, path, sheet), path = path)
  out <- data.frame(
    row = cells[[1L]],
    col = cells[[2L]],
    type = factor(CELL_TYPES[cells[[3L]] + 1L], levels = CELL_TYPES),
    value = cells[[4L]],
    number = cells[[5L]],
    stringsAsFactors = FALSE
  )
  # The date epoch is a property of the workbook, not of any cell, so it rides
  # along as an attribute rather than as a column. read_xlsx() needs it to turn
  # a serial number into a date; a caller working with cells directly needs it
  # for the same reason.
  attr(out, "date1904") <- cells[[6L]]
  out
}

# Turns `sheet` into the worksheet name the native layer wants. A position is
# resolved here rather than in C so that the workbook is walked by the same
# code path that xlsx_sheets() exposes, and an out-of-range position is a
# clear R-level error rather than a missing worksheet.
resolve_sheet <- function(path, sheet, call = sys.call(-1L)) {
  is_name <- is.character(sheet) && length(sheet) == 1L && !is.na(sheet)
  if (!is_name && (!is.numeric(sheet) || length(sheet) != 1L || is.na(sheet))) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`sheet` must be a single worksheet name or position.",
      path = path,
      call = call
    )
  }
  sheets <- zuxlsx_unwrap(.Call(C_xlsx_sheets, path), path = path)

  # A name is checked here rather than left to the native layer. Opening a
  # worksheet that does not exist yields a handle that reports no rows, so an
  # unknown name would otherwise be indistinguishable from an empty sheet --
  # the same confusion xlsx_sheets() avoids by refusing to return character(0).
  if (is_name) {
    if (!(sheet %in% sheets)) {
      zuxlsx_stop(
        "zuxlsx_sheet_error",
        paste0(
          "The workbook has no worksheet called ", encodeString(sheet, quote = '"'),
          ". It has: ", paste0(encodeString(sheets, quote = '"'), collapse = ", "), "."
        ),
        path = path,
        call = call
      )
    }
    return(sheet)
  }
  if (sheet < 1 || sheet > length(sheets)) {
    zuxlsx_stop(
      "zuxlsx_sheet_error",
      paste0(
        "`sheet` is ", sheet, ", but the workbook has ",
        length(sheets), " worksheet", if (length(sheets) == 1L) "" else "s", "."
      ),
      path = path,
      call = call
    )
  }
  sheets[[as.integer(sheet)]]
}
