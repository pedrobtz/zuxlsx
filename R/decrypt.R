# Agile decryption (design section 21c).
#
# Internal, and not yet reachable from any exported function: the reader does
# not yet read stream contents out of the CFB container, nor parse
# EncryptionInfo, so the caller supplies both. `params` mirrors agile_params in
# src/agile.h, with every binary field already base64-decoded; `package` is the
# whole EncryptedPackage stream, length prefix included.
#
# The password is converted to UTF-8 here and to UTF-16LE in C. It cannot be
# wiped: R strings are immutable and may have been copied before they arrive.
agile_decrypt <- function(package, password, params, path = NULL) {
  if (!is.character(password) || length(password) != 1L || is.na(password)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`password` must be a single non-missing string."
    )
  }
  password <- enc2utf8(password)
  if (!validUTF8(password)) {
    zuxlsx_stop(
      "zuxlsx_input_error",
      "`password` is not valid text in its declared encoding."
    )
  }
  zuxlsx_unwrap(.Call(C_agile_decrypt, params, password, package), path = path)
}
