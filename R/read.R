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
#'
#' # Each column takes the type its cells support.
#' readings <- read_xlsx(path)
#' readings
#' vapply(readings, function(x) class(x)[1], character(1))
#'
#' # A worksheet by name, and part of one by range.
#' read_xlsx(path, "notes")
#' read_xlsx(path, range = "B1:C3")
#'
#' # Without a header row, columns are named by position.
#' read_xlsx(path, range = "A2:B4", col_names = FALSE)
read_xlsx <- function(path, sheet = 1, col_names = TRUE, range = NULL) {
  if (!is.logical(col_names) || length(col_names) != 1L || is.na(col_names)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`col_names` must be TRUE or FALSE."
    )
  }
  bounds <- if (is.null(range)) NULL else parse_range(range)
  path <- check_path(path)
  sheet <- resolve_sheet(path, sheet)

  # Columns are built in C, from the cells it already holds. Doing it there
  # rather than here means a column's text is only ever allocated in R if the
  # column turns out to be character: on a wide numeric sheet most of the
  # worksheet never crosses the boundary at all.
  got <- zuxlsx_unwrap(
    .Call(
      C_read_xlsx, path, sheet, col_names,
      if (is.null(bounds)) {
        NULL
      } else {
        as.numeric(c(bounds$min_row, bounds$max_row, bounds$min_col, bounds$max_col))
      }
    ),
    path = path
  )
  if (is.null(got)) {
    return(data.frame())
  }

  cols <- got$columns
  # The epoch arithmetic stays in R. It is the fiddliest part of this package
  # -- two epochs, one of which counts a day that never existed -- and it is
  # vectorised, so running it here costs one call per date column rather than
  # one per cell.
  for (j in which(got$is_date)) {
    cols[[j]] <- to_datetime(cols[[j]], isTRUE(got$date1904))
  }

  out <- as.data.frame(cols, stringsAsFactors = FALSE, optional = TRUE)
  names(out) <- header_names(got$header, length(cols))
  out
}

# The header row, padded and de-duplicated, or X1..Xn where it gave nothing.
header_names <- function(header, n_col) {
  out <- paste0("X", seq_len(n_col))
  hit <- !is.na(header) & nzchar(header)
  out[hit] <- header[hit]
  make.unique(out, sep = "_")
}

# Excel stores a date as a number of days since an epoch that the workbook
# chooses. Neither epoch is the obvious one, and the 1900 system is not even
# internally consistent -- see shift_1900() below.
to_datetime <- function(serial, date1904) {
  origin <- if (date1904) "1904-01-01" else "1899-12-30"
  if (!date1904) {
    serial <- shift_1900(serial)
  }

  # A whole number is a date; a fraction carries a time of day, and losing it
  # by coercing to Date would be silent data loss.
  if (all(is.na(serial) | serial == trunc(serial))) {
    return(as.Date(serial, origin = origin))
  }
  as.POSIXct(serial * 86400, origin = paste(origin, "00:00:00"), tz = "UTC")
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
