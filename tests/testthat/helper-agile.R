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
# [MS-OFFCRYPTO] 2.3.4.11 to 2.3.4.15, AES-256 and SHA-512 as Excel writes
# them. The spin count defaults low, because R pays ~7 us per round; any
# count is valid.

agile_encrypt <- function(plaintext, password, spin_count = 1000, seed = 1) {
  skip_if_not_installed("zucrypt")
  withr::local_seed(seed)
  sha512 <- function(...) zucrypt::crypt_hash(c(...), "sha512")
  le32 <- function(i) as.raw(floor(i / 256^(0:3)) %% 256)
  random <- function(n) as.raw(sample(0:255, n, TRUE))
  pad16 <- function(x) c(x, raw((-length(x)) %% 16))
  cbc <- function(data, key, iv) {
    zucrypt::crypt_aes_cbc_encrypt_nopad(pad16(data), key, iv[1:16])
  }

  pw_salt <- random(16)
  kd_salt <- random(16)
  secret <- random(32)
  verifier <- random(16)
  hmac_key <- random(64)

  pw16 <- iconv(enc2utf8(password), "UTF-8", "UTF-16LE", toRaw = TRUE)[[1]]
  h <- sha512(pw_salt, pw16)
  for (i in seq_len(spin_count) - 1) h <- sha512(le32(i), h)
  derive <- function(block) sha512(h, as.raw(block))[1:32]

  enc_vin <- cbc(verifier, derive(c(0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79)), pw_salt)
  enc_vval <- cbc(sha512(verifier),
                  derive(c(0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e)), pw_salt)
  enc_kval <- cbc(secret, derive(c(0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6)), pw_salt)

  # 4096-byte segments, each CBC from IV = H(keyData salt || segment).
  n <- length(plaintext)
  segments <- lapply(seq(0, max(0, ceiling(n / 4096) - 1)), function(i) {
    if (n == 0) return(raw(0))
    chunk <- plaintext[(i * 4096 + 1):min(n, (i + 1) * 4096)]
    cbc(chunk, secret, sha512(kd_salt, le32(i)))
  })
  package <- c(as.raw(floor(n / 256^(0:7)) %% 256), unlist(segments))

  mac <- zucrypt::crypt_hmac(package, hmac_key, "sha512")
  enc_hkey <- cbc(hmac_key, secret,
                  sha512(kd_salt, as.raw(c(0x5f, 0xb2, 0xad, 0x01, 0x0c, 0xb9, 0xe1, 0xf6))))
  enc_hval <- cbc(mac, secret,
                  sha512(kd_salt, as.raw(c(0xa0, 0x67, 0x7f, 0x02, 0xb2, 0x2c, 0x84, 0x33))))

  cipher <- 'saltSize="16" blockSize="16" keyBits="256" hashSize="64" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512"'
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
  cfb_build(list(EncryptionInfo = info, EncryptedPackage = package))
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
