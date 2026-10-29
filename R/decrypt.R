# Agile decryption (design section 21c).
#
# Internal, kept for the tests: the readers decrypt in C through
# resolve_source() (section 21g), and decrypt_ole2() below is the same path
# from R. Here the caller supplies the parsed parameters and the stream:
# `params` mirrors agile_params in src/agile.h, with every binary field already
# base64-decoded; `package` is the whole EncryptedPackage stream, length prefix
# included.
#
# The password is converted to UTF-8 here and to UTF-16LE in C. It cannot be
# wiped: R strings are immutable and may have been copied before they arrive.
agile_decrypt <- function(package, password, params, path = NULL) {
  password <- check_password(password)
  zuxlsx_unwrap(.Call(C_agile_decrypt, params, password, package), path = path)
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
