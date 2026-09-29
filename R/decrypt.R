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
  password <- check_password(password)
  zuxlsx_unwrap(.Call(C_agile_decrypt, params, password, package), path = path)
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

# EncryptionInfo parsed in C (design section 21c, step 2): the version prefix
# checked, then the agile descriptor read into the list agile_decrypt()
# takes. Internal, and mostly for the tests, which compare it with the R
# parser in helper-ole2.R.
encryption_info <- function(stream, path = NULL) {
  zuxlsx_unwrap(.Call(C_encryption_info, stream), path = path)
}

# From a password-protected workbook's bytes to its plaintext package: the
# two streams out of the CFB container, EncryptionInfo parsed, the package
# decrypted. Steps 1 to 3; step 4 hands the result to the reader.
decrypt_ole2 <- function(bytes, password, path = NULL) {
  password <- check_password(password)
  zuxlsx_unwrap(.Call(C_decrypt_ole2, bytes, password), path = path)
}
