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
#'   \item{`zuxlsx_encrypted_error`}{The workbook is password-protected and
#'     no `password` was given. Raised in preference to
#'     `zuxlsx_unsupported_format_error` so that "needs a password" can be
#'     handled on its own.}
#'   \item{`zuxlsx_password_error`}{The `password` given is not the
#'     workbook's. A subclass of `zuxlsx_encrypted_error`, so one handler
#'     covers a password that is missing and one that is wrong. A damaged
#'     encryption header is indistinguishable from a wrong password, by
#'     design of the format.}
#'   \item{`zuxlsx_integrity_error`}{A password-protected workbook is damaged:
#'     its encrypted package does not match the integrity code stored with
#'     it, or its container or encryption parameters are inconsistent.
#'     Nothing is decrypted from a file that fails this check.}
#'   \item{`zuxlsx_unsupported_format_error`}{The file is a spreadsheet, but
#'     not one zuxlsx can read: an `.xlsb`, whose worksheets are binary rather
#'     than XML; a legacy `.xls`; or a workbook encrypted with a scheme other
#'     than agile encryption, such as Office 2007's standard encryption.
#'     Raised in preference to reporting such a file as corrupt, which is
#'     what it otherwise looks like.}
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
        "Pass its password as `password = ` to read it."
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
    agile_password = list(
      # Under zuxlsx_encrypted_error, so a handler that prompts for a password
      # when none was given also prompts again when the one given was wrong.
      # It is not an unsupported format: the file is readable, with the
      # right password.
      class = c("zuxlsx_password_error", "zuxlsx_encrypted_error"),
      message = paste0(
        "The password for '", path, "' is not correct.\n",
        "The workbook's password verifier did not match. If the password is ",
        "right, the file's encryption header is damaged; the two cannot be ",
        "told apart."
      )
    ),
    agile_integrity = list(
      class = "zuxlsx_integrity_error",
      message = paste0(
        "'", path, "' failed its integrity check.\n",
        "The password is correct, but the encrypted package does not match ",
        "the HMAC stored with it: the file was damaged or altered after it ",
        "was encrypted. Nothing was decrypted."
      )
    ),
    agile_malformed = list(
      class = "zuxlsx_integrity_error",
      message = paste0(
        "'", path, "' is a damaged encrypted workbook.\n",
        "Its encryption parameters or its encrypted package are ",
        "inconsistent, so it cannot be decrypted with any password."
      )
    ),
    agile_unsupported = list(
      # Not zuxlsx_encrypted_error: no password would help, so a handler that
      # prompts for one must not catch it.
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is encrypted with an algorithm zuxlsx does not ",
        "implement.\n",
        "zuxlsx decrypts agile encryption with AES in CBC mode and SHA-1 or ",
        "SHA-2, which is what Excel has written since 2013."
      )
    ),
    cfb_not_cfb = list(
      class = "zuxlsx_input_error",
      message = paste0("'", path, "' is not an OLE2 container.")
    ),
    cfb_malformed = list(
      # The container an encrypted workbook arrives in, damaged: the same
      # answer as a damaged encryption header inside it.
      class = "zuxlsx_integrity_error",
      message = paste0(
        "'", path, "' is a damaged OLE2 container.\n",
        "Its sector tables or directory are inconsistent, so the streams in ",
        "it cannot be read."
      )
    ),
    cfb_not_encrypted = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is an OLE2 container, but not an encrypted workbook.\n",
        "It holds no EncryptionInfo and EncryptedPackage streams."
      )
    ),
    # The four below are encrypted workbooks this package will not decrypt,
    # each named for what it is. None is zuxlsx_encrypted_error: no password
    # would help, so a handler prompting for one must not see them.
    encryption_standard = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' uses standard encryption, which zuxlsx does not ",
        "decrypt.\n",
        "That is Office 2007's scheme (AES-128, SHA-1). zuxlsx decrypts agile ",
        "encryption, which Excel has written since 2013: open the file in ",
        "Excel and save it again to convert it."
      )
    ),
    encryption_extensible = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' uses extensible encryption, from a third-party ",
        "provider, which zuxlsx does not decrypt."
      )
    ),
    encryption_unknown = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' is encrypted with a scheme whose version zuxlsx does ",
        "not recognise."
      )
    ),
    encryption_certificate = list(
      class = "zuxlsx_unsupported_format_error",
      message = paste0(
        "'", path, "' can only be opened with a certificate, not a ",
        "password.\n",
        "zuxlsx decrypts password-protected workbooks only."
      )
    ),
    agile_password_utf8 = list(
      class = "zuxlsx_input_error",
      message = "`password` must be a single non-missing string of valid text."
    ),
    agile_crypto = list(
      class = "zuxlsx_error",
      message = paste0(
        "The cryptographic backend failed while decrypting '", path, "' (",
        res$value, ")."
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
