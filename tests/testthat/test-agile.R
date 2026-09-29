# Agile decryption, design section 21c step 3: the C core, with the
# EncryptionInfo parameters read in R by helper-ole2.R.
#
# The fixtures were encrypted by msoffcrypto-tool, which shares no code with
# zucrypt or with this package. Decrypting them to the exact bytes it was
# given is the only independent evidence that the scheme is implemented
# correctly rather than consistently -- see fixtures/ole2/README.md.
#
# Every tampering test below starts from a file that decrypts, changes one
# thing, and asserts on the class. Which class matters: a wrong password, a
# damaged file and an algorithm this does not implement need three different
# responses from the caller. The builders it uses -- agile_fixture(),
# agile_agile_plaintext(), flip(), with_length() -- are in helper-ole2.R.

test_that("the fixture decrypts to exactly the bytes msoffcrypto-tool was given", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  out <- agile_decrypt(fx$package, "zuxlsx", fx$params, fx$path)
  expect_identical(out, agile_plaintext())
})

test_that("the decrypted package reads as the workbook it came from", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  out <- withr::local_tempfile(fileext = ".xlsx")
  writeBin(agile_decrypt(fx$package, "zuxlsx", fx$params, fx$path), out)
  expect_identical(
    read_xlsx(out, sheet = 2),
    read_xlsx(ole2_fixture("two-sheets-stored.xlsx"), sheet = 2)
  )
})

test_that("a non-ASCII password is hashed as UTF-16LE, surrogate pairs included", {
  # "zü✓🔑": one-, two-, three- and four-byte UTF-8. The last is outside the
  # BMP, so it only matches if it becomes a surrogate pair.
  fx <- agile_fixture("two-sheets-encrypted-utf16.xlsx")
  password <- "zü✓\U0001F511"
  expect_identical(agile_decrypt(fx$package, password, fx$params, fx$path),
                   agile_plaintext())

  # Each character is load-bearing: dropping the pair is a different password.
  expect_error(agile_decrypt(fx$package, "zü✓", fx$params, fx$path),
               class = "zuxlsx_password_error")
})

test_that("a password in another declared encoding is converted, not reinterpreted", {
  fx <- agile_fixture("two-sheets-encrypted-utf16.xlsx")
  # The same text, held as latin1 bytes where it can be: "zü" alone is not
  # the password, but it must fail as a wrong password -- having been
  # converted -- and never as invalid text.
  latin1 <- iconv("zü", "UTF-8", "latin1")
  expect_identical(Encoding(latin1), "latin1")
  expect_error(agile_decrypt(fx$package, latin1, fx$params, fx$path),
               class = "zuxlsx_password_error")
})

test_that("a wrong password is a password error, and an encrypted-workbook error", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  for (password in c("", "zuxls", "zuxlsx ", "ZUXLSX")) {
    cond <- expect_error(agile_decrypt(fx$package, password, fx$params, fx$path),
                         class = "zuxlsx_password_error")
    # So one handler covers "needs a password" and "that one was wrong".
    expect_s3_class(cond, "zuxlsx_encrypted_error")
    expect_false(inherits(cond, "zuxlsx_unsupported_format_error"))
  }
})

test_that("the spin count is the one the file declares", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  for (n in c(99999, 100001, 0)) {
    params <- fx$params
    params$password$spin_count <- n
    expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                 class = "zuxlsx_password_error", info = n)
  }
})

test_that("a password argument that is not one string of valid text is refused", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  bad_utf8 <- rawToChar(as.raw(c(0x7a, 0xc3)))
  Encoding(bad_utf8) <- "UTF-8"
  for (password in list(NA_character_, c("a", "b"), character(0), 1, NULL,
                        bad_utf8)) {
    expect_error(agile_decrypt(fx$package, password, fx$params, fx$path),
                 class = "zuxlsx_input_error")
  }
})

test_that("the C layer refuses malformed UTF-8 rather than repairing it", {
  # R validates first, so this reaches the C decoder directly. A repaired
  # password is a different password.
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  bytes <- list(
    overlong = c(0xc0, 0xaf),
    overlong_3 = c(0xe0, 0x80, 0xaf),
    surrogate = c(0xed, 0xa0, 0x80),
    too_large = c(0xf4, 0x90, 0x80, 0x80),
    truncated = c(0x7a, 0xe2, 0x9c),
    bare_continuation = c(0x80),
    invalid_lead = c(0xff)
  )
  for (name in names(bytes)) {
    password <- rawToChar(as.raw(bytes[[name]]))
    res <- .Call(C_agile_decrypt, fx$params, password, fx$package)
    expect_identical(res$status, "agile_password_utf8", info = name)
  }
})

test_that("altered ciphertext fails the integrity check before anything is decrypted", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  n <- length(fx$package)
  # First segment, second segment, the padding in the last block, and the
  # length prefix -- which the HMAC covers too.
  for (at in c(9, 8 + 4096 + 5, n, 1)) {
    expect_error(agile_decrypt(flip(fx$package, at), "zuxlsx", fx$params, fx$path),
                 class = "zuxlsx_integrity_error", info = at)
  }
  # A length made shorter, still consistent with the ciphertext.
  expect_error(agile_decrypt(with_length(fx$package, 4400), "zuxlsx",
                             fx$params, fx$path),
               class = "zuxlsx_integrity_error")
  # Trailing bytes the HMAC did not cover.
  expect_error(agile_decrypt(c(fx$package, as.raw(0)), "zuxlsx",
                             fx$params, fx$path),
               class = "zuxlsx_integrity_error")
})

test_that("altered dataIntegrity fields fail the integrity check", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  for (field in c("encrypted_hmac_key", "encrypted_hmac_value")) {
    params <- fx$params
    params[[field]] <- flip(params[[field]], 1)
    cond <- expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                         class = "zuxlsx_integrity_error", info = field)
    expect_false(inherits(cond, "zuxlsx_password_error"))
  }
})

test_that("an altered key encryptor is caught, never turned into plaintext", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")

  # The verifier: indistinguishable from a wrong password, by construction.
  for (field in c("encrypted_verifier_hash_input", "encrypted_verifier_hash_value")) {
    params <- fx$params
    params$password[[field]] <- flip(params$password[[field]], 1)
    expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                 class = "zuxlsx_password_error", info = field)
  }

  # The intermediate key: the verifier still passes, so this is the case the
  # HMAC exists for -- a wrong key would otherwise decrypt to garbage.
  params <- fx$params
  params$password$encrypted_key_value <- flip(params$password$encrypted_key_value, 1)
  expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
               class = "zuxlsx_integrity_error")
})

test_that("an algorithm this does not implement is refused by name", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  cases <- list(
    list("cipher_algorithm", "DES"),
    list("cipher_algorithm", "RC4"),
    list("cipher_chaining", "ChainingModeCFB"),
    list("hash_algorithm", "MD5"),
    list("hash_algorithm", "WHIRLPOOL"),
    list("hash_algorithm", "RIPEMD-160")
  )
  for (which in c("key_data", "password")) {
    for (case in cases) {
      params <- fx$params
      params[[which]][[case[[1]]]] <- case[[2]]
      info <- paste(which, case[[1]], case[[2]])
      cond <- expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                           class = "zuxlsx_unsupported_format_error", info = info)
      # No password helps, so a handler prompting for one must not see it.
      expect_false(inherits(cond, "zuxlsx_encrypted_error"), info = info)
    }
  }
})

test_that("sizes that contradict the named algorithm are malformed, not guessed at", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  cases <- list(
    list("block_size", 8),
    list("key_bits", 100),
    list("key_bits", 512),
    list("hash_size", 20),        # SHA-1's size, under SHA512
    list("salt_size", 15),        # disagrees with the salt itself
    list("salt", raw(0)),
    list("salt_size", NA_real_),
    list("key_bits", 256.5),
    list("hash_size", -64),
    list("cipher_algorithm", NA_character_),
    list("hash_algorithm", NULL)
  )
  for (which in c("key_data", "password")) {
    for (case in cases) {
      params <- fx$params
      if (is.null(case[[2]])) {
        params[[which]][case[[1]]] <- list(NULL)
      } else {
        params[[which]][[case[[1]]]] <- case[[2]]
      }
      expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                   class = "zuxlsx_integrity_error",
                   info = paste(which, case[[1]], format(case[[2]])))
    }
  }
})

test_that("a spin count beyond the specification's limit is refused, not run", {
  # [MS-OFFCRYPTO] caps spinCount at 10,000,000. The file chooses it, so
  # without the cap a hostile workbook chooses how long the open takes.
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  for (n in c(10000001, 2^31, -1, 1.5, NA)) {
    params <- fx$params
    params$password$spin_count <- n
    expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                 class = "zuxlsx_integrity_error", info = n)
  }
})

test_that("encrypted fields too short or not whole blocks are malformed", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  shorten <- function(x, n) x[seq_len(n)]
  cases <- list(
    list("password", "encrypted_verifier_hash_input", 8),
    list("password", "encrypted_verifier_hash_value", 48),   # < hashSize 64
    list("password", "encrypted_verifier_hash_value", 63),
    list("password", "encrypted_key_value", 16),             # < 256 bits
    list("password", "encrypted_key_value", 0),
    list(NULL, "encrypted_hmac_key", 32),
    list(NULL, "encrypted_hmac_value", 50)
  )
  for (case in cases) {
    params <- fx$params
    if (is.null(case[[1]])) {
      params[[case[[2]]]] <- shorten(params[[case[[2]]]], case[[3]])
    } else {
      params[[case[[1]]]][[case[[2]]]] <-
        shorten(params[[case[[1]]]][[case[[2]]]], case[[3]])
    }
    expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                 class = "zuxlsx_integrity_error",
                 info = paste(case[[2]], case[[3]]))
  }
})

test_that("a declared length the ciphertext cannot back is refused before allocating", {
  # The status, not only the class: "agile_malformed" is decided from the
  # length prefix alone, before the password, the HMAC or any allocation --
  # where "agile_integrity", the same class, would mean it got as far as the
  # HMAC. The lengths near 2^64 are ones a double can hold exactly.
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  status <- function(package) {
    .Call(C_agile_decrypt, fx$params, "zuxlsx", package)$status
  }
  ciphertext <- length(fx$package) - 8
  for (n in c(ciphertext + 1, ciphertext + 4096, 2^53, 2^63, 2^64 - 4096)) {
    expect_identical(status(with_length(fx$package, n)), "agile_malformed",
                     info = format(n, scientific = FALSE))
  }

  # Fits in bytes, but not once rounded up to a whole block: 4097 bytes need
  # 4112 of ciphertext, and 4100 are present.
  short <- fx$package[seq_len(8 + 4100)]
  expect_identical(status(with_length(short, 4097)), "agile_malformed")
  # Whereas 4096 need exactly 4096, so that gets as far as the HMAC.
  expect_identical(status(with_length(short, 4096)), "agile_integrity")

  for (package in list(raw(0), raw(7), fx$package[1:7])) {
    expect_identical(status(package), "agile_malformed")
    expect_error(agile_decrypt(package, "zuxlsx", fx$params, fx$path),
                 class = "zuxlsx_integrity_error")
  }
})

test_that("parameters of the wrong shape are malformed, not a crash", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  for (params in list(list(), NULL, "x", unname(fx$params),
                      list(key_data = fx$params$key_data))) {
    expect_error(agile_decrypt(fx$package, "zuxlsx", params, fx$path),
                 class = "zuxlsx_integrity_error")
  }
  expect_error(agile_decrypt(as.integer(fx$package), "zuxlsx", fx$params, fx$path),
               class = "zuxlsx_integrity_error")
})

test_that("decrypting twice gives the same bytes, and needs no state between calls", {
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  a <- agile_decrypt(fx$package, "zuxlsx", fx$params, fx$path)
  expect_error(agile_decrypt(fx$package, "wrong", fx$params, fx$path),
               class = "zuxlsx_password_error")
  b <- agile_decrypt(fx$package, "zuxlsx", fx$params, fx$path)
  expect_identical(a, b)
})

test_that("zucrypt's own namespace can be loaded alongside, and both work", {
  # zuxlsx holds a private copy of the backend, linked from libzucrypt.a;
  # zucrypt.so holds another. They must not interfere.
  skip_if_not_installed("zucrypt")
  loadNamespace("zucrypt")
  fx <- agile_fixture("two-sheets-encrypted.xlsx")
  expect_identical(agile_decrypt(fx$package, "zuxlsx", fx$params, fx$path),
                   agile_plaintext())
  expect_identical(
    zucrypt::crypt_hash(charToRaw("abc"), "sha256"),
    as.raw(c(0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
             0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
             0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad))
  )
})
