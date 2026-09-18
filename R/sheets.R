#' List the worksheets in an xlsx workbook
#'
#' @param path Path to an `.xlsx` file.
#'
#' @return A character vector of worksheet names, in workbook order. A workbook
#'   always has at least one.
#' @export
#' @seealso [zuxlsx-conditions] for the errors this can raise.
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#' if (nzchar(path)) xlsx_sheets(path)
xlsx_sheets <- function(path) {
  path <- check_path(path)
  zuxlsx_unwrap(.Call(C_xlsx_sheets, path), path = path)
}

#' Report the native libraries zuxlsx was built against
#'
#' zuxlsx vendors the 'xlsxio' reader and links 'Expat' and 'miniz' statically
#' out of the `zuxml` and `zukomp` packages, through `LinkingTo`. This reports
#' what it actually got, which is the quickest way to tell a stale build from
#' a current one.
#'
#' @return A list with elements `xlsxio`, `expat` and `miniz`.
#' @export
#' @examples
#' zuxlsx_native()
zuxlsx_native <- function() {
  zuxlsx_unwrap(.Call(C_zuxlsx_native))
}

# Normalises `path` for the native layer, or raises zuxlsx_input_error.
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
