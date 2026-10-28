# An agile *encryptor*, for building password-protected workbooks of any
# content inside a test: an encrypted .xlsb, an encrypted package whose
# workbook part is broken, one whose ciphertext has been tampered with after
# the HMAC was taken. No committed fixture can be all of those.
#
# It uses zucrypt's R functions, so it is not independent of the decryptor,
# which uses zucrypt's C -- a round trip through the two proves the plumbing,
# not the cryptography. The msoffcrypto-tool fixtures in fixtures/ole2/ are
# what prove the scheme, and remain the reference for it. Tests using this
# skip without zucrypt, which is in Suggests.
#
# [MS-OFFCRYPTO] 2.3.4.11 to 2.3.4.15. The defaults are AES-256 and SHA-512,
# as Excel writes them; `hash` and `key_bits` reach every combination the
# decryptor accepts, including the ones where the hash is shorter than the key
# and the derived key is padded with 0x36 (2.3.4.11). The spin count defaults
# low, because R pays ~7 us per round; any count is valid.

agile_encrypt <- function(plaintext, password, spin_count = 1000, seed = 1,
                          hash = "SHA512", key_bits = 256, version = 3L) {
  skip_if_not_installed("zucrypt")
  withr::local_seed(seed)
  algo <- tolower(sub("-", "", hash))
  H <- function(...) zucrypt::crypt_hash(c(...), algo)
  hash_size <- length(H(raw(0)))
  key_size <- key_bits / 8
  le32 <- function(i) as.raw(floor(i / 256^(0:3)) %% 256)
  random <- function(n) as.raw(sample(0:255, n, TRUE))
  pad16 <- function(x) c(x, raw((-length(x)) %% 16))
  # 2.3.4.11: truncate, or pad with 0x36, to the length wanted.
  fit <- function(x, n) {
    if (length(x) >= n) x[seq_len(n)] else c(x, rep(as.raw(0x36), n - length(x)))
  }
  cbc <- function(data, key, iv) {
    zucrypt::crypt_aes_cbc_encrypt_nopad(pad16(data), key, fit(iv, 16))
  }

  pw_salt <- random(16)
  kd_salt <- random(16)
  secret <- random(key_size)
  verifier <- random(16)
  hmac_key <- random(hash_size)

  pw16 <- iconv(enc2utf8(password), "UTF-8", "UTF-16LE", toRaw = TRUE)[[1]]
  h <- H(pw_salt, pw16)
  for (i in seq_len(spin_count) - 1) h <- H(le32(i), h)
  derive <- function(block) fit(H(h, as.raw(block)), key_size)

  enc_vin <- cbc(verifier, derive(c(0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79)), pw_salt)
  enc_vval <- cbc(H(verifier),
                  derive(c(0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e)), pw_salt)
  enc_kval <- cbc(secret, derive(c(0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6)), pw_salt)

  # 4096-byte segments, each CBC from IV = H(keyData salt || segment).
  n <- length(plaintext)
  segments <- lapply(seq(0, max(0, ceiling(n / 4096) - 1)), function(i) {
    if (n == 0) return(raw(0))
    chunk <- plaintext[(i * 4096 + 1):min(n, (i + 1) * 4096)]
    cbc(chunk, secret, H(kd_salt, le32(i)))
  })
  package <- c(as.raw(floor(n / 256^(0:7)) %% 256), unlist(segments))

  mac <- zucrypt::crypt_hmac(package, hmac_key, algo)
  enc_hkey <- cbc(hmac_key, secret,
                  H(kd_salt, as.raw(c(0x5f, 0xb2, 0xad, 0x01, 0x0c, 0xb9, 0xe1, 0xf6))))
  enc_hval <- cbc(mac, secret,
                  H(kd_salt, as.raw(c(0xa0, 0x67, 0x7f, 0x02, 0xb2, 0x2c, 0x84, 0x33))))

  cipher <- paste0(
    'saltSize="16" blockSize="16" keyBits="', key_bits, '" hashSize="',
    hash_size, '" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" ',
    'hashAlgorithm="', hash, '"'
  )
  xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
    '<encryption xmlns="http://schemas.microsoft.com/office/2006/encryption" ',
    'xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password">',
    '<keyData ', cipher, ' saltValue="', base64_encode(kd_salt), '"/>',
    '<dataIntegrity encryptedHmacKey="', base64_encode(enc_hkey),
    '" encryptedHmacValue="', base64_encode(enc_hval), '"/>',
    '<keyEncryptors><keyEncryptor uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password">',
    '<p:encryptedKey spinCount="', format(spin_count, scientific = FALSE), '" ', cipher,
    ' saltValue="', base64_encode(pw_salt),
    '" encryptedVerifierHashInput="', base64_encode(enc_vin),
    '" encryptedVerifierHashValue="', base64_encode(enc_vval),
    '" encryptedKeyValue="', base64_encode(enc_kval), '"/>',
    '</keyEncryptor></keyEncryptors></encryption>'
  )
  info <- c(as.raw(c(4, 0, 4, 0, 0x40, 0, 0, 0)), charToRaw(xml))
  cfb_build(list(EncryptionInfo = info, EncryptedPackage = package), version)
}

# Writes bytes to a temporary .xlsx that lasts as long as the calling test.
local_workbook_bytes <- function(bytes, env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = env)
  writeBin(bytes, path)
  path
}

# A workbook of the given parts, as a raw vector, via helper-zip.R's writer.
workbook_bytes <- function(parts = workbook_parts()) {
  path <- tempfile(fileext = ".xlsx")
  on.exit(unlink(path))
  write_workbook(path, parts)
  readBin(path, "raw", file.size(path))
}

# The msoffcrypto-tool fixtures and their plaintext, by role.
stored <- function() ole2_fixture("two-sheets-stored.xlsx")
encrypted <- function() ole2_fixture("two-sheets-encrypted.xlsx")
utf16 <- function() ole2_fixture("two-sheets-encrypted-utf16.xlsx")

# utf16()'s password, "zü✓🔑": one-, two-, three- and four-byte UTF-8. Built
# from code points because a literal mixing a BMP character with a \U escape
# beyond it is double-encoded by R's parser in a locale that is not UTF-8,
# which is how CRAN's Debian clang machine runs the tests.
utf16_password <- function(n = 4L) {
  intToUtf8(c(0x7a, 0xfc, 0x2713, 0x1F511)[seq_len(n)])
}
