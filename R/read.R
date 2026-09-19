#' Read a worksheet into a data frame
#'
#' Reads a worksheet and assembles its cells into columns, giving each column
#' the type its cells support. This is the high-level reader; [xlsx_cells()] is
#' the cell-by-cell view underneath it.
#'
#' A worksheet may leave a row out of its XML rather than write an empty one.
#' Such a row is kept, as a row of `NA`, wherever it falls -- including
#' directly beneath the header. Keeping every blank row is easier to predict
#' than keeping only the interior ones, and `range` is the way to begin
#' further down the sheet.
#'
#' Column types are inferred by promotion. A column of blanks is logical, one
#' of booleans stays logical, numbers give a double, and anything that mixes
#' types, or that holds a string or a cell error, becomes character. A column
#' whose cells are all dates becomes a `Date`, or a `POSIXct` when any of them
#' carries a time of day.
#'
#' @param path Path to an `.xlsx` file.
#' @param sheet The worksheet to read: either its name, or its position in the
#'   workbook.
#' @param col_names Whether the first row holds column names. When `FALSE`,
#'   columns are named `X1`, `X2` and so on.
#' @param range An A1-style cell range limiting what is read, or `NULL` for the
#'   whole worksheet. Either corner may name a cell, a column or a row, so
#'   `"B2:D10"` takes a rectangle, `"A:C"` takes three columns in full, and
#'   `"2:10"` takes nine rows in full. The corners may be given in either
#'   order. A range is read as its own rectangle: cells outside it are ignored,
#'   the top-left becomes the first row and column, and columns the range
#'   covers appear even where the worksheet left them empty. When `col_names`
#'   is `TRUE` the first row of the range supplies the names.
#'
#' @return A data frame.
#' @export
#' @seealso [xlsx_cells()] for the cells themselves, and [xlsx_sheets()] to
#'   list the worksheets.
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#' if (nzchar(path)) read_xlsx(path)
#' if (nzchar(path)) read_xlsx(path, range = "A1:B5")
read_xlsx <- function(path, sheet = 1, col_names = TRUE, range = NULL) {
  if (!is.logical(col_names) || length(col_names) != 1L || is.na(col_names)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`col_names` must be TRUE or FALSE."
    )
  }
  bounds <- if (is.null(range)) NULL else parse_range(range)

  cells <- xlsx_cells(path, sheet)
  date1904 <- isTRUE(attr(cells, "date1904"))
  if (!is.null(bounds)) {
    cells <- clip_cells(cells, bounds)
  }

  if (nrow(cells) == 0L) {
    return(data.frame())
  }

  # A range asks for its own rectangle, whether or not every part of it holds
  # a cell: "A1:D3" is three rows of four columns even if column D is empty
  # throughout. Without a range the extent is whatever the sheet used.
  n_col <- if (!is.null(bounds) && !is.na(bounds$min_col)) {
    bounds$max_col - bounds$min_col + 1
  } else {
    max(cells$col)
  }
  row_span <- if (!is.null(bounds) && !is.na(bounds$min_row)) {
    seq_len(bounds$max_row - bounds$min_row + 1)
  } else {
    seq.int(min(cells$row), max(cells$row))
  }

  header_row <- if (col_names) row_span[1L] else NA_real_
  body_span <- if (col_names) row_span[-1L] else row_span
  body <- if (col_names) cells[cells$row != header_row, , drop = FALSE] else cells

  names_out <- column_names(cells, header_row, n_col, col_names)
  cols <- vector("list", n_col)
  for (j in seq_len(n_col)) {
    cols[[j]] <- build_column(
      body[body$col == j, , drop = FALSE], body_span, date1904
    )
  }

  out <- as.data.frame(cols, stringsAsFactors = FALSE, optional = TRUE)
  names(out) <- names_out
  out
}

# The header row, padded and de-duplicated, or X1..Xn when there is none.
column_names <- function(cells, header_row, n_col, col_names) {
  fallback <- paste0("X", seq_len(n_col))
  if (!col_names) {
    return(fallback)
  }
  head_cells <- cells[cells$row == header_row, , drop = FALSE]
  out <- fallback
  hit <- head_cells$col[!is.na(head_cells$value) & nzchar(head_cells$value)]
  out[hit] <- head_cells$value[!is.na(head_cells$value) & nzchar(head_cells$value)]
  make.unique(out, sep = "_")
}

# Turns one column's cells into a vector, at the type its cells support.
#
# `rows` is the row numbers the column must cover, passed in rather than
# derived from the cells: a column that is blank in the middle, or absent
# entirely, still has to line up with its neighbours, and a range asks for its
# own height whether or not cells fill it.
#
# It is a span rather than the rows that happen to carry a cell for a second
# reason. A worksheet may omit an empty row from its XML, and xlsxio pads such
# a gap with a single row however wide it is -- data on rows 1, 2 and 5
# arrives as rows 1, 2, 4, 5. Every cell carries its own row number, so
# spanning the range reconstructs the gap and ignores that padding.
build_column <- function(col_cells, rows, date1904) {
  n <- length(rows)
  if (n == 0L) {
    return(logical(0))
  }
  at <- match(col_cells$row, rows)

  present <- col_cells[as.character(col_cells$type) != "blank", , drop = FALSE]
  at_present <- at[as.character(col_cells$type) != "blank"]
  types <- unique(as.character(present$type))

  # An empty column, or one of nothing but blanks, is logical NA: the type
  # that promotes to anything else without a coercion warning.
  if (length(types) == 0L) {
    return(rep(NA, n))
  }
  if (identical(types, "boolean")) {
    out <- rep(NA, n)
    out[at_present] <- present$number != 0
    return(out)
  }
  if (identical(types, "number")) {
    out <- rep(NA_real_, n)
    out[at_present] <- present$number
    return(out)
  }
  if (identical(types, "date")) {
    return(build_date_column(present, at_present, n, date1904))
  }
  # Anything else -- a string, a cell error, or a mix of types -- is character.
  out <- rep(NA_character_, n)
  out[at_present] <- present$value
  out
}

# Excel stores a date as a number of days since an epoch that the workbook
# chooses. Neither epoch is the obvious one, and the 1900 system is not even
# internally consistent -- see shift_1900() below.
build_date_column <- function(present, at_present, n, date1904) {
  origin <- if (date1904) "1904-01-01" else "1899-12-30"
  serial <- if (date1904) present$number else shift_1900(present$number)

  # A whole number is a date; a fraction carries a time of day, and losing it
  # by coercing to Date would be silent data loss.
  if (all(is.na(serial) | serial == trunc(serial))) {
    out <- rep(NA_real_, n)
    out[at_present] <- serial
    return(as.Date(out, origin = origin))
  }
  out <- rep(NA_real_, n)
  out[at_present] <- serial * 86400
  as.POSIXct(out, origin = paste(origin, "00:00:00"), tz = "UTC")
}

# Excel reproduces a Lotus 1-2-3 bug: under the 1900 date system it treats 1900
# as a leap year, so serial 60 is 29 February 1900, a day that never existed.
#
# That makes a single origin impossible. From serial 61 (1 March 1900) onward
# the phantom day has been counted, and 1899-12-30 is right. Below it the day
# has not been counted yet, and the origin is really 1899-12-31 -- so serial 1
# is 1 January 1900, which is what Excel shows. Using 1899-12-30 throughout, as
# is common, puts every date before March 1900 one day early.
#
# Serial 60 itself denotes no real date and becomes NA rather than being bent
# onto one of its neighbours.
shift_1900 <- function(serial) {
  out <- serial
  below <- !is.na(serial) & serial < 60
  out[below] <- serial[below] + 1
  out[!is.na(serial) & serial == 60] <- NA_real_
  out
}
