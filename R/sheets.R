#' List the worksheets in an xlsx workbook
#'
#' @param path Path to an `.xlsx` file.
#'
#' @return A character vector of worksheet names, in workbook order.
#' @export
#' @examples
#' path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
#' if (nzchar(path)) xlsx_sheets(path)
xlsx_sheets <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single non-missing string.", call. = FALSE)
  }
  path <- path.expand(path)
  if (!file.exists(path)) {
    stop("`path` does not exist: ", path, call. = FALSE)
  }
  .Call(C_xlsx_sheets, normalizePath(path, winslash = "/", mustWork = TRUE))
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
  .Call(C_zuxlsx_native)
}
