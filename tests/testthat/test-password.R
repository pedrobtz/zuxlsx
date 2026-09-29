# Reading password-protected workbooks: `password =` on the five readers,
# design section 21c step 4.
#
# The msoffcrypto-tool fixtures prove the readers see exactly the workbook
# that was encrypted. The agile_encrypt() cases -- built in the test, needing
# zucrypt -- reach what no fixture can: an encrypted .xlsb, an encrypted
# package whose parts are broken, the callback reader holding the decrypted
# package while R code runs. Its fixture shorthands -- stored(), encrypted(),
# utf16() -- are in helper-agile.R.

test_that("every reader reads a password-protected workbook as its plaintext", {
  for (case in list(list(encrypted(), "zuxlsx"),
                    list(utf16(), "zü✓\U0001F511"))) {
    path <- case[[1]]
    pw <- case[[2]]
    expect_identical(xlsx_sheets(path, password = pw), xlsx_sheets(stored()))
    for (sheet in list(1, 2, "notes")) {
      expect_identical(read_xlsx(path, sheet, password = pw),
                       read_xlsx(stored(), sheet), info = format(sheet))
      expect_identical(xlsx_cells(path, sheet, password = pw),
                       xlsx_cells(stored(), sheet))
      expect_identical(xlsx_rows(path, sheet, password = pw),
                       xlsx_rows(stored(), sheet))
    }
    expect_identical(read_xlsx(path, col_names = FALSE, range = "A1:B3", password = pw),
                     read_xlsx(stored(), col_names = FALSE, range = "A1:B3"))
  }
})

test_that("the callback reader reads it too, holding the plaintext across calls", {
  # A chunk size of 1 means a callback per row, each made while the reader
  # is open on the decrypted package in memory.
  collect <- function(path, password = NULL) {
    chunks <- list()
    xlsx_read_cells(path, 1, function(cells) {
      chunks[[length(chunks) + 1L]] <<- cells
      TRUE
    }, chunk_size = 1, password = password)
    chunks
  }
  got <- collect(encrypted(), "zuxlsx")
  expect_gt(length(got), 1L)
  expect_identical(got, collect(stored()))
})

test_that("an error inside the callback still disposes of the decrypted package", {
  # The finalizer that closes the reader also wipes and frees the plaintext;
  # the error unwinds past the C stack, and nothing may be left for the
  # garbage collector to trip over.
  for (i in 1:3) {
    expect_error(
      xlsx_read_cells(encrypted(), 1, function(cells) stop("boom"),
                      chunk_size = 1, password = "zuxlsx"),
      "boom"
    )
  }
  gc()
  expect_identical(read_xlsx(encrypted(), password = "zuxlsx"), read_xlsx(stored()))
})

test_that("stopping the callback read early is fine on an encrypted workbook", {
  n <- 0
  stopped <- xlsx_read_cells(encrypted(), 1, function(cells) {
    n <<- n + 1
    FALSE
  }, chunk_size = 1, password = "zuxlsx")
  expect_true(stopped)
  expect_identical(n, 1)
})

test_that("without a password, every reader says the workbook needs one", {
  readers <- list(
    function(p) xlsx_sheets(p),
    function(p) read_xlsx(p),
    function(p) xlsx_cells(p),
    function(p) xlsx_rows(p),
    function(p) xlsx_read_cells(p, 1, function(x) TRUE)
  )
  for (f in readers) {
    cond <- expect_error(f(encrypted()), class = "zuxlsx_encrypted_error")
    expect_false(inherits(cond, "zuxlsx_password_error"))
  }
})

test_that("a wrong password is a password error from every reader", {
  readers <- list(
    function(p, pw) xlsx_sheets(p, password = pw),
    function(p, pw) read_xlsx(p, password = pw),
    function(p, pw) xlsx_cells(p, password = pw),
    function(p, pw) xlsx_rows(p, password = pw),
    function(p, pw) xlsx_read_cells(p, 1, function(x) TRUE, password = pw)
  )
  for (f in readers) {
    for (pw in c("", "wrong", "ZUXLSX")) {
      cond <- expect_error(f(encrypted(), pw), class = "zuxlsx_password_error")
      # One handler catches a missing password and a wrong one.
      expect_s3_class(cond, "zuxlsx_encrypted_error")
    }
  }
})

test_that("a password is ignored for a workbook that has none", {
  plain <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
  expect_identical(read_xlsx(plain, password = "anything"), read_xlsx(plain))
  expect_identical(xlsx_sheets(plain, password = "anything"), xlsx_sheets(plain))
})

test_that("a password changes nothing for a legacy .xls or another OLE2 file", {
  expect_error(read_xlsx(ole2_fixture("legacy.xls"), password = "zuxlsx"),
               class = "zuxlsx_unsupported_format_error")
  cond <- expect_error(read_xlsx(ole2_fixture("unknown-ole2.bin"), password = "zuxlsx"),
                       class = "zuxlsx_unsupported_format_error")
  expect_false(inherits(cond, "zuxlsx_encrypted_error"))
})

test_that("the password argument is validated by every reader", {
  for (pw in list(NA_character_, c("a", "b"), 1, TRUE, character(0))) {
    expect_error(read_xlsx(encrypted(), password = pw), class = "zuxlsx_input_error")
    expect_error(xlsx_sheets(encrypted(), password = pw), class = "zuxlsx_input_error")
    expect_error(xlsx_read_cells(encrypted(), 1, function(x) TRUE, password = pw),
                 class = "zuxlsx_input_error")
  }
})

test_that("standard encryption is refused by name, with a password or without", {
  path <- encrypted()
  info <- cfb_stream(path, "EncryptionInfo")
  info[1:4] <- as.raw(c(3, 0, 2, 0))                  # version 3.2: standard
  file <- local_workbook_bytes(cfb_build(list(
    EncryptionInfo = info,
    EncryptedPackage = cfb_stream(path, "EncryptedPackage")
  )))
  cond <- expect_error(read_xlsx(file, password = "zuxlsx"),
                       class = "zuxlsx_unsupported_format_error")
  expect_false(inherits(cond, "zuxlsx_encrypted_error"))
  expect_match(conditionMessage(cond), "standard encryption")
  # Without a password it is still, first, a password-protected workbook.
  expect_error(read_xlsx(file), class = "zuxlsx_encrypted_error")
})

test_that("a tampered encrypted workbook is an integrity error, and nothing is read", {
  bytes <- readBin(encrypted(), "raw", file.size(encrypted()))
  start <- le_u32(bytes, cfb_entry_offset(bytes, "EncryptedPackage") + 0x74)
  # A byte of ciphertext, well inside the package's first sector.
  at <- (start + 1) * 512 + 100
  bytes[at + 1] <- xor(bytes[at + 1], as.raw(1))
  file <- local_workbook_bytes(bytes)
  expect_error(read_xlsx(file, password = "zuxlsx"), class = "zuxlsx_integrity_error")
  expect_error(xlsx_sheets(file, password = "zuxlsx"), class = "zuxlsx_integrity_error")
})

test_that("agile_encrypt() round-trips, so the cases below mean what they say", {
  bytes <- agile_encrypt(agile_plaintext(), "s3cret")
  expect_identical(decrypt_ole2(bytes, "s3cret"), agile_plaintext())
  file <- local_workbook_bytes(bytes)
  expect_identical(read_xlsx(file, 2, password = "s3cret"), read_xlsx(stored(), 2))
})

test_that("a decrypted package that is an .xlsb is reported as one", {
  # The failure diagnostics look inside the decrypted package in memory, not
  # at the encrypted file on disk.
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- NULL
  parts[["xl/workbook.bin"]] <- as.raw(1:20)
  file <- local_workbook_bytes(agile_encrypt(workbook_bytes(parts), "pw"))
  expect_error(xlsx_sheets(file, password = "pw"),
               class = "zuxlsx_unsupported_format_error")
  expect_identical(.Call(C_xlsx_sheets, file, "pw")$status, "format_xlsb")
})

test_that("a decrypted package with a broken workbook part names the part", {
  parts <- workbook_parts()
  parts[["xl/workbook.xml"]] <- "<workbook><sheets><sheet"
  file <- local_workbook_bytes(agile_encrypt(workbook_bytes(parts), "pw"))
  cond <- expect_error(xlsx_sheets(file, password = "pw"), class = "zuxlsx_xml_error")
  expect_match(conditionMessage(cond), "xl/workbook.xml", fixed = TRUE)
})

test_that("a decrypted package that is not a ZIP is a ZIP error", {
  file <- local_workbook_bytes(agile_encrypt(charToRaw("not a zip at all"), "pw"))
  expect_error(read_xlsx(file, password = "pw"), class = "zuxlsx_zip_error")
})

test_that("large packages decrypt across many segments", {
  # 200 x 20 cells is well past one 4096-byte segment. (grid_workbook()
  # names columns A to Z, so no wider.)
  skip_if_not_installed("zucrypt")
  path <- withr::local_tempfile(fileext = ".xlsx")
  write_workbook(path, grid_workbook(200, 20))
  plain <- readBin(path, "raw", file.size(path))
  expect_gt(length(plain), 4 * 4096)
  file <- local_workbook_bytes(agile_encrypt(plain, "pw"))
  expect_identical(read_xlsx(file, password = "pw"), read_xlsx(path))
})
