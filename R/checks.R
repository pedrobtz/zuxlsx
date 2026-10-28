# Argument checks shared by every reader. Each raises zuxlsx_input_error, or
# zuxlsx_sheet_error for a worksheet the workbook does not have, and returns
# the argument in the form the native layer takes.

# Normalises `path` for the native layer.
check_path <- function(path, call = sys.call(-1L)) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`path` must be a single non-missing string.",
      call = call
    )
  }
  path <- path.expand(path)
  if (!file.exists(path)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      paste0("`path` does not exist: ", path),
      path = path,
      call = call
    )
  }
  # A directory reaches the reader as an unopenable archive otherwise, which
  # would be reported as a ZIP error rather than as the wrong kind of path.
  if (dir.exists(path)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      paste0("`path` is a directory, not a file: ", path),
      path = path,
      call = call
    )
  }
  normalizePath(path, winslash = "/", mustWork = TRUE)
}

# `password =` on the readers: NULL, or a password as check_password() takes it.
check_optional_password <- function(password, call = sys.call(-1L)) {
  if (is.null(password)) NULL else check_password(password, call = call)
}

# A password as the C layer takes it: one string, UTF-8, valid.
check_password <- function(password, call = sys.call(-1L)) {
  if (!is.character(password) || length(password) != 1L || is.na(password)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`password` must be a single non-missing string.",
      call = call
    )
  }
  password <- enc2utf8(password)
  if (!validUTF8(password)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`password` is not valid text in its declared encoding.",
      call = call
    )
  }
  password
}

# A whole number between 1 and the largest R integer, as an integer.
check_count <- function(x, arg, call = sys.call(-1L)) {
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) ||
    x < 1 || x != trunc(x) || x > .Machine$integer.max) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      paste0(
        "`", arg, "` must be a single whole number between 1 and ",
        .Machine$integer.max, "."
      ),
      call = call
    )
  }
  as.integer(x)
}

# Turns `sheet` into the worksheet name the native layer wants. A position is
# resolved here rather than in C so that the workbook is walked by the same
# code path that xlsx_sheets() exposes, and an out-of-range position is a
# clear R-level error rather than a missing worksheet.
resolve_sheet <- function(path, sheet, password = NULL, call = sys.call(-1L)) {
  is_name <- is.character(sheet) && length(sheet) == 1L && !is.na(sheet)
  is_position <- is.numeric(sheet) && length(sheet) == 1L &&
    is.finite(sheet) && sheet == trunc(sheet)
  if (!is_name && !is_position) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`sheet` must be a single worksheet name or a whole-number position.",
      path = path,
      call = call
    )
  }
  sheets <- zuxlsx_unwrap(.Call(C_xlsx_sheets, path, password), path = path)

  # A name is checked here rather than left to the native layer. Opening a
  # worksheet that does not exist yields a handle that reports no rows, so an
  # unknown name would otherwise be indistinguishable from an empty sheet --
  # the same confusion xlsx_sheets() avoids by refusing to return character(0).
  if (is_name) {
    if (!(sheet %in% sheets)) {
      zuxlsx_stop(
        "zuxlsx_sheet_error",
        paste0(
          "The workbook has no worksheet called ",
          encodeString(sheet, quote = '"'),
          ". It has: ",
          paste0(encodeString(sheets, quote = '"'), collapse = ", "),
          "."
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
  sheets[[sheet]]
}
