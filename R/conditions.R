# Structured conditions (design section 15).
#
# Every error zuxlsx raises carries a class, so that calling code can tell a
# corrupt archive from a missing file without matching on message text. The
# classes nest: each specific class is followed by `zuxlsx_error`, so
# `tryCatch(zuxlsx_error = ...)` catches all of them.
#
# The wording is not part of the contract and may change; the classes are.

#' Conditions raised by zuxlsx
#'
#' All errors raised by zuxlsx carry a condition class, so that they can be
#' caught by kind rather than by matching on the message text, which is not
#' stable. Every class below is a subclass of `zuxlsx_error`.
#'
#' \describe{
#'   \item{`zuxlsx_input_error`}{An argument was not usable: a `path` that is
#'     not a single string, or a file that does not exist.}
#'   \item{`zuxlsx_zip_error`}{The file could not be opened as a ZIP archive.
#'     It is missing, unreadable, truncated, or not a ZIP at all.}
#'   \item{`zuxlsx_ooxml_error`}{The ZIP archive opened but is not a workbook.
#'     A valid workbook declares at least one worksheet.}
#'   \item{`zuxlsx_sheet_error`}{The workbook opened, but the requested
#'     worksheet is not in it.}
#'   \item{`zuxlsx_unsupported_format_error`}{The file is a spreadsheet, but
#'     not one zuxlsx can read: an `.xlsb`, whose worksheets are binary rather
#'     than XML, or an OLE2 file, which is either a legacy `.xls` or an
#'     encrypted workbook. Raised in preference to reporting such a file as
#'     corrupt, which is what it otherwise looks like.}
#'   \item{`zuxlsx_memory_error`}{An allocation failed while reading.}
#' }
#'
#' Conditions carry the offending `path` in a `path` element, where one
#' applies.
#'
#' @name zuxlsx-conditions
#' @examples
#' tryCatch(
#'   xlsx_sheets("no-such-file.xlsx"),
#'   zuxlsx_input_error = function(e) conditionMessage(e)
#' )
NULL

zuxlsx_condition <- function(class, message, path = NULL, call = NULL) {
  structure(
    class = c(class, "zuxlsx_error", "error", "condition"),
    list(message = message, call = call, path = path)
  )
}

zuxlsx_stop <- function(class, message, path = NULL, call = sys.call(-1L)) {
  stop(zuxlsx_condition(class, message, path = path, call = call))
}

# Turns the (status, value) pair the C layer returns into either the value or a
# classed condition. The C layer never calls Rf_error(), so this is the only
# place a native failure becomes an R error.
zuxlsx_unwrap <- function(res, path = NULL, call = sys.call(-1L)) {
  if (identical(res$status, "ok")) {
    return(res$value)
  }

  info <- switch(res$status,
    zip_open = list(
      class = "zuxlsx_zip_error",
      message = paste0(
        "Cannot open '", path, "' as an xlsx workbook.\n",
        "The file is not a readable ZIP archive. It may be truncated, ",
        "corrupt, or not an xlsx file at all."
      )
    ),
    format_ole2 = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is an OLE2 file, not an xlsx workbook.\n",
        "That is either a legacy .xls workbook or an encrypted, ",
        "password-protected workbook. zuxlsx reads neither: it reads xlsx, ",
        "and it cannot decrypt."
      )
    ),
    format_xlsb = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is an xlsb workbook, not an xlsx workbook.\n",
        "An xlsb stores its worksheets as binary records rather than XML. ",
        "zuxlsx reads xlsx only."
      )
    ),
    sheet_not_found = list(
      class = "zuxlsx_sheet_error",
      message = paste0(
        "'", path, "' has no such worksheet."
      )
    ),
    ooxml_no_sheets = list(
      class = "zuxlsx_ooxml_error",
      message = paste0(
        "'", path, "' is a ZIP archive but not an xlsx workbook.\n",
        "It declares no worksheets."
      )
    ),
    memory = list(
      class = "zuxlsx_memory_error",
      message = paste0("Ran out of memory while reading '", path, "'.")
    ),
    bad_path = list(
      class = "zuxlsx_input_error",
      message = "`path` must be a single non-missing string."
    ),
    # A status R does not know about means the C layer grew one and this
    # function was not updated. Report it rather than returning NULL.
    list(
      class = "zuxlsx_error",
      message = paste0(
        "Internal error: unrecognised status '", res$status,
        "' from the native layer."
      )
    )
  )

  zuxlsx_stop(info$class, info$message, path = path, call = call)
}
