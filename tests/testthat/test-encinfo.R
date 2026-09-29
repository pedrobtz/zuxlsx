# EncryptionInfo parsed in C, and the chain from container bytes to the
# plaintext package: src/encinfo.c and C_decrypt_ole2(), design section 21c
# step 2.
#
# The C parser is compared with helper-ole2.R's, written separately, on the
# real fixtures. Everything after that rewrites the fixture's descriptor to
# shape one case, and asserts on the class -- and, where several refusals
# share one, on the native status that says which.

test_that("the C parser reads the fixtures exactly as the R parser does", {
  for (fixture in c("two-sheets-encrypted.xlsx", "two-sheets-encrypted-utf16.xlsx")) {
    info <- cfb_stream(ole2_fixture(fixture), "EncryptionInfo")
    expect_identical(encryption_info(info), agile_params(info), info = fixture)
  }
})

test_that("a password-protected workbook decrypts from its bytes alone", {
  cases <- list(
    "two-sheets-encrypted.xlsx" = "zuxlsx",
    "two-sheets-encrypted-utf16.xlsx" = "zü✓\U0001F511"
  )
  for (fixture in names(cases)) {
    path <- ole2_fixture(fixture)
    bytes <- readBin(path, "raw", file.size(path))
    expect_identical(decrypt_ole2(bytes, cases[[fixture]], path), agile_plaintext(),
                     info = fixture)
    cond <- expect_error(decrypt_ole2(bytes, "wrong", path),
                         class = "zuxlsx_password_error", info = fixture)
    expect_s3_class(cond, "zuxlsx_encrypted_error")
  }
})

test_that("a repacked container decrypts the same, so the tests below can build them", {
  expect_identical(decrypt_ole2(encrypted_container(), "zuxlsx"), agile_plaintext())
})

test_that("standard, extensible and unknown schemes are refused by name", {
  # The version prefix decides, before any XML is read -- a standard file's
  # descriptor is binary, and reading it as agile would derive a wrong key
  # and report a wrong password.
  xml <- fixture_encryption_xml()
  cases <- list(
    list(2, 2, "encryption_standard"),
    list(3, 2, "encryption_standard"),
    list(4, 2, "encryption_standard"),
    list(3, 3, "encryption_extensible"),
    list(4, 3, "encryption_extensible"),
    list(1, 1, "encryption_unknown"),
    list(4, 5, "encryption_unknown"),
    list(5, 4, "encryption_unknown"),
    list(2, 3, "encryption_unknown")
  )
  for (case in cases) {
    stream <- encryption_info_stream(xml, case[[1]], case[[2]])
    info <- paste0(case[[1]], ".", case[[2]])
    expect_identical(encryption_info_status(stream), case[[3]], info = info)
    cond <- expect_error(decrypt_ole2(encrypted_container(stream), "zuxlsx"),
                         class = "zuxlsx_unsupported_format_error", info = info)
    expect_false(inherits(cond, "zuxlsx_encrypted_error"), info = info)
  }
})

test_that("agile's reserved flags must be 0x40", {
  stream <- encryption_info_stream(fixture_encryption_xml(), flags = 0x24)
  expect_identical(encryption_info_status(stream), "agile_malformed")
  expect_error(decrypt_ole2(encrypted_container(stream), "zuxlsx"),
               class = "zuxlsx_integrity_error")
})

test_that("namespaces are matched by URI, whatever the prefixes", {
  # The same document with the encryption namespace bound to a prefix and the
  # password namespace to a different one -- or made the default on the
  # element that uses it.
  xml <- fixture_encryption_xml()
  prefixed <- gsub("<(/?)(encryption|keyData|dataIntegrity|keyEncryptors|keyEncryptor)\\b",
                   "<\\1enc:\\2", xml)
  prefixed <- sub('xmlns="http://schemas.microsoft.com/office/2006/encryption"',
                  'xmlns:enc="http://schemas.microsoft.com/office/2006/encryption"',
                  prefixed, fixed = TRUE)
  prefixed <- gsub("p:encryptedKey", "pwd:encryptedKey", prefixed, fixed = TRUE)
  prefixed <- sub('xmlns:p="', 'xmlns:pwd="', prefixed, fixed = TRUE)
  expect_false(identical(prefixed, xml))

  default_ns <- sub(
    "<p:encryptedKey ",
    '<encryptedKey xmlns="http://schemas.microsoft.com/office/2006/keyEncryptor/password" ',
    xml, fixed = TRUE
  )
  for (doc in list(prefixed, default_ns)) {
    stream <- encryption_info_stream(doc)
    expect_identical(encryption_info(stream),
                     encryption_info(encryption_info_stream(xml)))
    expect_identical(decrypt_ole2(encrypted_container(stream), "zuxlsx"),
                     agile_plaintext())
  }
})

test_that("the right local name in the wrong namespace is not the element", {
  xml <- fixture_encryption_xml()
  wrong <- list(
    # keyData moved out of the encryption namespace.
    sub("<keyData ", '<keyData xmlns="urn:elsewhere" ', xml, fixed = TRUE),
    # The document element itself.
    sub('xmlns="http://schemas.microsoft.com/office/2006/encryption"',
        'xmlns="urn:elsewhere"', xml, fixed = TRUE)
  )
  for (doc in wrong) {
    expect_identical(encryption_info_status(encryption_info_stream(doc)),
                     "agile_malformed")
  }
  # The password encryptedKey in the certificate namespace: there is then no
  # password key encryptor at all.
  cert <- sub('xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password"',
              'xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/certificate"',
              xml, fixed = TRUE)
  expect_identical(encryption_info_status(encryption_info_stream(cert)),
                   "encryption_certificate")
})

test_that("a DOCTYPE is refused, as is any entity past the built-ins", {
  xml <- fixture_encryption_xml()
  body <- sub("^<\\?xml[^>]*\\?>", "", xml)
  decl <- '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
  docs <- list(
    doctype = paste0(decl, "<!DOCTYPE encryption>", body),
    internal_subset = paste0(decl, '<!DOCTYPE encryption [<!ENTITY a "x">]>', body),
    external = paste0(decl, '<!DOCTYPE encryption SYSTEM "file:///etc/passwd">', body),
    undefined_entity = sub('saltSize="16"', 'saltSize="&n;"', xml, fixed = TRUE)
  )
  for (name in names(docs)) {
    expect_identical(encryption_info_status(encryption_info_stream(docs[[name]])),
                     "agile_malformed", info = name)
  }
  # The built-in entities are fine, in a place that does not matter.
  ok <- sub("<keyEncryptors>", "<keyEncryptors><!-- &amp; --><x a='&lt;&gt;'/>",
            xml, fixed = TRUE)
  expect_identical(encryption_info_status(encryption_info_stream(ok)), "ok")
})

test_that("missing or repeated elements are malformed", {
  xml <- fixture_encryption_xml()
  key_data <- regmatches(xml, regexpr("<keyData[^>]*/>", xml))
  integrity <- regmatches(xml, regexpr("<dataIntegrity[^>]*/>", xml))
  encrypted_key <- regmatches(xml, regexpr("<p:encryptedKey[^>]*/>", xml))
  docs <- list(
    no_key_data = sub(key_data, "", xml, fixed = TRUE),
    no_integrity = sub(integrity, "", xml, fixed = TRUE),
    two_key_data = sub(key_data, paste0(key_data, key_data), xml, fixed = TRUE),
    two_integrity = sub(integrity, paste0(integrity, integrity), xml, fixed = TRUE),
    two_keys = sub(encrypted_key, paste0(encrypted_key, encrypted_key), xml, fixed = TRUE),
    # keyData nested one level too deep is not keyData.
    nested = sub(key_data, paste0("<keyEncryptors>", key_data, "</keyEncryptors>"),
                 sub(key_data, "", xml, fixed = TRUE), fixed = TRUE)
  )
  for (name in names(docs)) {
    expect_identical(encryption_info_status(encryption_info_stream(docs[[name]])),
                     "agile_malformed", info = name)
  }
})

test_that("only a certificate key encryptor means no password can open it", {
  xml <- fixture_encryption_xml()
  cert <- sub('uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password"',
              'uri="http://schemas.microsoft.com/office/2006/keyEncryptor/certificate"',
              xml, fixed = TRUE)
  stream <- encryption_info_stream(cert)
  expect_identical(encryption_info_status(stream), "encryption_certificate")
  cond <- expect_error(decrypt_ole2(encrypted_container(stream), "zuxlsx"),
                       class = "zuxlsx_unsupported_format_error")
  expect_false(inherits(cond, "zuxlsx_encrypted_error"))

  # A certificate encryptor beside the password one is ignored.
  both <- sub("<keyEncryptors>", paste0(
    "<keyEncryptors><keyEncryptor uri=\"http://schemas.microsoft.com/office/2006/",
    "keyEncryptor/certificate\"><c:encryptedKey/></keyEncryptor>"
  ), xml, fixed = TRUE)
  expect_identical(decrypt_ole2(encrypted_container(encryption_info_stream(both)),
                                "zuxlsx"),
                   agile_plaintext())
})

test_that("unknown elements and attributes are ignored", {
  xml <- fixture_encryption_xml()
  extended <- sub("<keyData ", '<keyData futureAttribute="1" ', xml, fixed = TRUE)
  extended <- sub("</encryption>", "<future><keyData/></future></encryption>",
                  extended, fixed = TRUE)
  expect_identical(
    decrypt_ole2(encrypted_container(encryption_info_stream(extended)), "zuxlsx"),
    agile_plaintext()
  )
})

test_that("counts are whole decimal numbers, or NA", {
  xml <- fixture_encryption_xml()
  for (value in c("", "16x", "-16", " 16", "1e1", "0x10", "99999999999",
                  "2147483648", "１６")) {
    doc <- sub('spinCount="100000"', paste0('spinCount="', value, '"'), xml,
               fixed = TRUE)
    parsed <- encryption_info(encryption_info_stream(doc))
    expect_identical(parsed$password$spin_count, NA_real_, info = value)
  }
  doc <- sub('spinCount="100000"', 'spinCount="2147483647"', xml, fixed = TRUE)
  expect_identical(encryption_info(encryption_info_stream(doc))$password$spin_count,
                   2147483647)
})

test_that("base64 is decoded exactly, and strictly", {
  xml <- fixture_encryption_xml()
  with_salt <- function(text) {
    doc <- sub('saltValue="[^"]*"', paste0('saltValue="', text, '"'), xml)
    encryption_info(encryption_info_stream(doc))$key_data$salt
  }
  set.seed(9)
  for (n in c(1:40, 255)) {
    bytes <- as.raw(sample(0:255, n, TRUE))
    expect_identical(with_salt(base64_encode(bytes)), bytes, info = n)
  }
  for (bad in c("", "A", "AAA", "AAAAA", "AA=A", "A===", "=AAA", "AA A",
                "AAA-", "AA==AAAA", "AAAAéAAA")) {
    expect_null(with_salt(bad))
  }
})

test_that("a missing or undecodable parameter is malformed at decryption", {
  xml <- fixture_encryption_xml()
  docs <- list(
    sub(' spinCount="100000"', "", xml, fixed = TRUE),
    sub('encryptedKeyValue="', 'encryptedKeyValue="!', xml, fixed = TRUE),
    sub(' hashAlgorithm="SHA512"', "", xml, fixed = TRUE),
    sub('encryptedHmacKey="[^"]*"', 'encryptedHmacKey=""', xml)
  )
  for (doc in docs) {
    expect_error(decrypt_ole2(encrypted_container(encryption_info_stream(doc)),
                              "zuxlsx"),
                 class = "zuxlsx_integrity_error")
  }
})

test_that("every truncation of the descriptor is refused, never misread", {
  # Exactly those that still hold the closing </encryption> parse -- only the
  # trailing whitespace after it can go.
  stream <- encryption_info_stream(fixture_encryption_xml())
  close_tag <- charToRaw("</encryption>")
  ends <- which(vapply(seq_along(stream), function(i) {
    i >= length(close_tag) &&
      identical(stream[(i - length(close_tag) + 1):i], close_tag)
  }, logical(1)))
  expect_length(ends, 1L)

  n <- seq(0, length(stream) - 1)
  status <- vapply(n, function(k) encryption_info_status(stream[seq_len(k)]),
                   character(1))
  expect_identical(status[n < ends], rep("agile_malformed", sum(n < ends)))
  expect_identical(unique(status[n >= ends]), "ok")
})

test_that("containers that are not encrypted workbooks are told apart", {
  zip <- readBin(system.file("extdata", "two-sheets.xlsx", package = "zuxlsx"),
                 "raw", 1e6)
  expect_error(decrypt_ole2(zip, "zuxlsx"), class = "zuxlsx_input_error")

  other <- cfb_build(list(Workbook = as.raw(1:100)))
  expect_identical(.Call(C_decrypt_ole2, other, "zuxlsx")$status, "cfb_not_encrypted")
  expect_error(decrypt_ole2(other, "zuxlsx"), class = "zuxlsx_unsupported_format_error")

  # One of the two streams, without the other.
  path <- ole2_fixture("two-sheets-encrypted.xlsx")
  half <- cfb_build(list(EncryptionInfo = cfb_stream(path, "EncryptionInfo")))
  expect_identical(.Call(C_decrypt_ole2, half, "zuxlsx")$status, "cfb_not_encrypted")
})

test_that("the password argument is checked as for agile_decrypt()", {
  bytes <- encrypted_container()
  for (password in list(NA_character_, c("a", "b"), 1, NULL)) {
    expect_error(decrypt_ole2(bytes, password), class = "zuxlsx_input_error")
  }
})
