# A1-style cell references, and the rectangles they describe.
#
# A worksheet ends at XFD1048576: 1048576 rows and 16384 columns.
#
# Excel addresses a column by letters in a bijective base-26 system: A to Z,
# then AA, AB and so on. It is not ordinary base 26 -- there is no zero digit,
# so "A" is 1 rather than 0 and "AA" is 27 rather than 26.

MAX_ROWS <- 1048576
MAX_COLS <- 16384

# "A" -> 1, "Z" -> 26, "AA" -> 27, for one run of letters.
column_number <- function(letters_in) {
  digits <- utf8ToInt(toupper(letters_in)) - utf8ToInt("A") + 1L
  sum(digits * 26^rev(seq_along(digits) - 1L))
}

# Splits one corner of a range. Each part may be absent: "B2" bounds both
# axes, "B" only the column, "2" only the row.
parse_corner <- function(corner) {
  m <- regmatches(corner, regexec("^([A-Za-z]*)([0-9]*)$", corner))[[1L]]
  if (length(m) != 3L || (!nzchar(m[2L]) && !nzchar(m[3L]))) {
    return(NULL)
  }
  list(
    col = if (nzchar(m[2L])) column_number(m[2L]) else NA_real_,
    row = if (nzchar(m[3L])) as.numeric(m[3L]) else NA_real_
  )
}

# Turns "B2:D10" into the rectangle it means: min_row, max_row, min_col and
# max_col, the vector C_read_xlsx takes. A bound that the range does not
# constrain is NA, so "A:C" limits columns and leaves every row in, and "2:10"
# does the opposite.
#
# Corners are normalised, so "D10:B2" is the same rectangle as "B2:D10".
parse_range <- function(range, call = sys.call(-1L)) {
  bad <- function() {
    zuxlsx_stop(
      "zuxlsx_input_error",
      paste0(
        "`range` must be an A1-style cell range such as \"B2:D10\", ",
        "\"A:C\" or \"2:10\", not ", encodeString(range, quote = "\""), "."
      ),
      call = call
    )
  }
  if (!is.character(range) || length(range) != 1L || is.na(range)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`range` must be a single string, or NULL.",
      call = call
    )
  }

  parts <- strsplit(range, ":", fixed = TRUE)[[1L]]
  if (length(parts) != 2L) {
    bad()
  }
  from <- parse_corner(parts[1L])
  to <- parse_corner(parts[2L])
  if (is.null(from) || is.null(to)) {
    bad()
  }
  # Both corners have to constrain the same axes, or the rectangle is not
  # defined: "A1:C" names a column for one corner and a cell for the other.
  if (is.na(from$row) != is.na(to$row) || is.na(from$col) != is.na(to$col)) {
    bad()
  }
  if (isTRUE(from$row == 0) || isTRUE(to$row == 0)) {
    bad()
  }
  rows <- c(from$row, to$row)
  cols <- c(from$col, to$col)
  if (any(rows > MAX_ROWS, na.rm = TRUE) || any(cols > MAX_COLS, na.rm = TRUE)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      paste0(
        "`range` ", encodeString(range, quote = "\""),
        " reaches past XFD1048576, the last cell a worksheet can have."
      ),
      call = call
    )
  }

  c(min(rows), max(rows), min(cols), max(cols))
}
