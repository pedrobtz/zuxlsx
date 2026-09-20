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
#'   \item{`zuxlsx_xml_error`}{A part of the workbook is not well-formed XML.
#'     Raised in preference to `zuxlsx_ooxml_error` when the failure is the
#'     XML itself rather than what it says, and names the part and line.}
#'   \item{`zuxlsx_ooxml_error`}{The ZIP archive opened but is not a workbook.
#'     A valid workbook declares at least one worksheet.}
#'   \item{`zuxlsx_sheet_error`}{The workbook opened, but the requested
#'     worksheet is not in it.}
#'   \item{`zuxlsx_encrypted_error`}{The workbook is password-protected. Its
#'     contents are encrypted and this package cannot decrypt them. Raised in
#'     preference to `zuxlsx_unsupported_format_error` so that "needs a
#'     password" can be handled on its own -- it is the one unsupported
#'     format the caller can do something about.}
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
    xml_malformed = list(
      class = "zuxlsx_xml_error",
      message = paste0(
        "'", path, "' contains XML that is not well formed.\n",
        "The part ", encodeString(res$value$part, quote = "'"),
        " could not be parsed",
        if (isTRUE(res$value$line > 0)) paste0(" (line ", res$value$line, ")") else "",
        "."
      )
    ),
    format_encrypted = list(
      # A subclass, not a replacement. Code already catching
      # zuxlsx_unsupported_format_error keeps working -- an encrypted
      # workbook *is* a format this package does not support -- while code
      # that wants to prompt for a password can catch the specific one.
      class = c("zuxlsx_encrypted_error", "zuxlsx_unsupported_format_error"),
      message = paste0(
        "'", path, "' is a password-protected workbook.\n",
        "Its contents are encrypted, and zuxlsx cannot decrypt them. ",
        "Remove the password in Excel and save a copy, or decrypt the file ",
        "with a tool that supports it."
      )
    ),
    format_xls = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is a legacy .xls workbook, not an xlsx workbook.\n",
        "An .xls stores its worksheets as BIFF binary records rather than ",
        "XML. zuxlsx reads xlsx only. Open it in Excel and save as .xlsx."
      )
    ),
    format_ole2 = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is an OLE2 file, not an xlsx workbook.\n",
        "Its directory names neither an encrypted package nor a BIFF ",
        "workbook, so it is some other OLE2 document. zuxlsx reads xlsx only."
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
