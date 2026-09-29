#' @keywords internal
"_PACKAGE"

## usethis namespace: start
## No .fixes: the entry points are registered as C_xlsx_sheets and
## C_zuxlsx_native already, and .fixes = "C_" would prefix those again.
#' @useDynLib zuxlsx, .registration = TRUE
## usethis namespace: end
NULL

# The DLL owns a reference to zucrypt's backend, taken in R_init_zuxlsx and
# dropped in R_unload_zuxlsx. R runs the latter only when the DLL is unloaded,
# and nothing unloads it unless the namespace asks.
.onUnload <- function(libpath) {
  library.dynam.unload("zuxlsx", libpath)
}
