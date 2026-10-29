# OLE2 containers: what they are, and what the reader says about each.
#
# A password-protected .xlsx is not a damaged .xlsx. It is an OLE2/CFB
# container holding the encrypted package, which is also what a legacy .xls
# is -- so the eight-byte signature identifies the container and not which of
# the two it holds. The directory does, and src/zuxlsx.c reads it (through
# src/cfb.c) to give each its own answer.
#
# Fixtures come from tools/make-ole2.R and msoffcrypto-tool; see
# fixtures/ole2/MANIFEST.tsv.

test_that("the fixtures are readable as CFB, not just magic bytes", {
  # If the generator produced something that merely starts with the right
  # eight bytes, every test below would pass while testing nothing.
  for (name in c("encrypted-agile.xlsx", "legacy.xls", "unknown-ole2.bin")) {
    entries <- cfb_read(ole2_fixture(name))
    expect_true(length(entries) > 1L)
    expect_identical(entries[[1]]$name, "Root Entry", info = name)
  }
})

test_that("an encrypted workbook is identifiable from its directory alone", {
  # The fact the classifier is built on: the two formats are
  # distinguishable without decrypting anything, without a password, and
  # without reading a byte of ciphertext.
  names <- cfb_stream_names(ole2_fixture("encrypted-agile.xlsx"))
  expect_true("EncryptionInfo" %in% names)
  expect_true("EncryptedPackage" %in% names)

  names <- cfb_stream_names(ole2_fixture("legacy.xls"))
  expect_true("Workbook" %in% names)
  expect_false("EncryptionInfo" %in% names)

  names <- cfb_stream_names(ole2_fixture("unknown-ole2.bin"))
  expect_false("EncryptionInfo" %in% names)
  expect_false("Workbook" %in% names)
})

test_that("EncryptedPackage begins with the plaintext length", {
  # [MS-OFFCRYPTO] 2.3.4.4: eight little-endian bytes giving the size of the
  # package before encryption, then the segments. Whatever reads this later
  # must not mistake those eight bytes for ciphertext.
  entries <- cfb_read(ole2_fixture("encrypted-agile.xlsx"))
  pkg <- Filter(function(e) e$name == "EncryptedPackage", entries)[[1]]
  expect_gt(pkg$size, 8)
})

test_that("every OLE2 container is reported as unsupported, not corrupt", {
  # The distinction that matters to a user: nothing here is damaged, and no
  # amount of retrying or re-downloading will help.
  for (name in c("encrypted-agile.xlsx", "legacy.xls", "unknown-ole2.bin")) {
    expect_error(xlsx_read(ole2_fixture(name)),
                 class = "zuxlsx_unsupported_format_error", info = name)
  }
})

test_that("an encrypted workbook and a legacy .xls get different answers", {
  # The distinction this whole exercise is about. Both are OLE2 containers,
  # and until the reader learned to read the CFB directory both produced the
  # same message -- which told someone with a password-protected file that it
  # might be a legacy .xls, and someone with a legacy .xls that it might need
  # a password.
  encrypted <- tryCatch(xlsx_read(ole2_fixture("encrypted-agile.xlsx")),
                        condition = function(e) e)
  legacy <- tryCatch(xlsx_read(ole2_fixture("legacy.xls")),
                     condition = function(e) e)

  expect_s3_class(encrypted, "zuxlsx_encrypted_error")
  expect_false(inherits(legacy, "zuxlsx_encrypted_error"))

  expect_identical(native_status(ole2_fixture("encrypted-agile.xlsx")),
                   "format_encrypted")
  expect_identical(native_status(ole2_fixture("legacy.xls")), "format_xls")
})

test_that("the encrypted condition is a subclass, so old handlers still work", {
  # Code written before this distinction existed catches
  # zuxlsx_unsupported_format_error. Narrowing the class without keeping that
  # would be a silent break for every such caller.
  cond <- tryCatch(xlsx_read(ole2_fixture("encrypted-agile.xlsx")),
                   condition = function(e) e)
  expect_s3_class(cond, "zuxlsx_encrypted_error")
  expect_s3_class(cond, "zuxlsx_unsupported_format_error")
  expect_s3_class(cond, "zuxlsx_error")
})

test_that("an OLE2 container that is neither is still reported honestly", {
  # The reader must not reach for the better message when it does not know.
  cond <- tryCatch(xlsx_read(ole2_fixture("unknown-ole2.bin")),
                   condition = function(e) e)
  expect_s3_class(cond, "zuxlsx_unsupported_format_error")
  expect_false(inherits(cond, "zuxlsx_encrypted_error"))
  expect_identical(native_status(ole2_fixture("unknown-ole2.bin")), "format_ole2")
})

test_that("a real encrypted workbook has the structure the synthetic one models", {
  # two-sheets-encrypted.xlsx is genuinely Agile-encrypted, produced by
  # msoffcrypto-tool. The synthetic fixture above is a model of it, and a
  # model nobody compares against the real thing is a model that drifts.
  real <- cfb_stream_names(ole2_fixture("two-sheets-encrypted.xlsx"))
  expect_true("EncryptionInfo" %in% real)
  expect_true("EncryptedPackage" %in% real)

  synthetic <- cfb_stream_names(ole2_fixture("encrypted-agile.xlsx"))
  expect_true(all(c("EncryptionInfo", "EncryptedPackage") %in% synthetic))

  # A real file carries the DataSpaces machinery too, which the synthetic one
  # deliberately omits. Recorded so the omission stays a decision: if the
  # reader ever needs those streams, the model has to grow them.
  expect_true("DataSpaceMap" %in% real)
  expect_false("DataSpaceMap" %in% synthetic)
})

test_that("the encrypted fixture's plaintext reads like the workbook it came from", {
  # two-sheets-stored.xlsx is inst/extdata/two-sheets.xlsx repacked with its
  # parts stored rather than deflated, purely to clear the 4081-byte floor
  # msoffcrypto-tool 6.0.0 corrupts below (see fixtures/ole2/README.md).
  # Asserting the repack changed nothing is what makes it usable as the
  # expected result of decrypting the two encrypted fixtures.
  expect_identical(
    xlsx_read(ole2_fixture("two-sheets-stored.xlsx")),
    xlsx_read(system.file("extdata", "two-sheets.xlsx", package = "zuxlsx"))
  )
})

test_that("the encrypted package is large enough to avoid the mini stream", {
  # Not a property of zuxlsx, and it is still worth a test: the day someone
  # regenerates this fixture from a smaller workbook, msoffcrypto-tool will
  # write a corrupt container and exit 0, and the failure will surface as an
  # unrelated decryption error much later.
  entries <- cfb_read(ole2_fixture("two-sheets-encrypted.xlsx"))
  pkg <- Filter(function(e) e$name == "EncryptedPackage", entries)[[1]]
  expect_gte(pkg$size, 4096)
})

test_that("a real encrypted workbook is recognised as encrypted", {
  # The synthetic fixture proves the classifier reads a directory this
  # package wrote. This proves it reads one msoffcrypto-tool wrote, which is
  # the only one of the two that resembles what users will hand it.
  expect_error(xlsx_read(ole2_fixture("two-sheets-encrypted.xlsx")),
               class = "zuxlsx_encrypted_error")
  expect_identical(native_status(ole2_fixture("two-sheets-encrypted.xlsx")),
                   "format_encrypted")
})

test_that("every entry point reports an OLE2 container the same way", {
  # xlsx_read() is not the only door in. A user calling xlsx_sheets() on an
  # encrypted workbook should not get a different story.
  path <- ole2_fixture("encrypted-agile.xlsx")
  for (fn in list(xlsx_read, xlsx_sheets, xlsx_cells)) {
    expect_error(fn(path), class = "zuxlsx_unsupported_format_error")
  }
})


# --- hostile containers ------------------------------------------------------
#
# The classifier is new C that reads attacker-controlled offsets, lengths and
# chain pointers out of a file. Everything it does is bounded, and these are
# the tests that say so rather than the comments.

test_that("a truncated container produces a condition, never a crash", {
  src <- readBin(ole2_fixture("two-sheets-encrypted.xlsx"), "raw",
                 file.size(ole2_fixture("two-sheets-encrypted.xlsx")))
  tmp <- withr::local_tempfile(fileext = ".xlsx")

  # Only a zuxlsx condition counts: an unclassed R error or a warning would
  # mean damage reached R code that did not expect it, and propagates.
  #
  # Every length through the header and the first sectors, which is where
  # the header, the FAT and the directory live, then a sparse sweep over the
  # rest. A cut anywhere must end the walk, not read past the end of it.
  lengths <- c(0:200, seq(201L, length(src), by = 211L))
  # Under gctorture, every 7th cut: the same paths, a seventh of the cost.
  if (light_tests()) lengths <- lengths[seq(1L, length(lengths), by = 7L)]
  for (n in lengths) {
    writeBin(src[seq_len(n)], tmp)
    result <- tryCatch(xlsx_read(tmp), zuxlsx_error = function(e) class(e)[1])
    expect_true(is.character(result), info = paste("truncated to", n))
  }
})

test_that("a corrupted directory or FAT produces a condition", {
  src <- readBin(ole2_fixture("two-sheets-encrypted.xlsx"), "raw",
                 file.size(ole2_fixture("two-sheets-encrypted.xlsx")))
  tmp <- withr::local_tempfile(fileext = ".xlsx")

  # Seeded, so a failure is reproducible rather than something that happened
  # once on somebody's machine.
  withr::local_seed(20260920)
  for (i in seq_len(if (light_tests()) 20L else 150L)) {
    x <- src
    # Weighted towards the first 600 bytes: header, DIFAT and the sector the
    # directory usually starts in.
    pos <- sample(c(seq_len(600L), seq_along(x)), size = sample.int(6L, 1L))
    x[pos] <- as.raw(sample.int(256L, length(pos), replace = TRUE) - 1L)
    writeBin(x, tmp)
    result <- tryCatch(xlsx_read(tmp), zuxlsx_error = function(e) class(e)[1])
    expect_true(is.character(result), info = paste("corruption", i))
  }
})

test_that("a self-referential FAT chain terminates", {
  # The specific shape a bounded walk exists to survive: a directory sector
  # whose FAT entry points back at itself. Unbounded, this is an infinite
  # loop inside a .Call with no interrupt check.
  src <- readBin(ole2_fixture("two-sheets-encrypted.xlsx"), "raw",
                 file.size(ole2_fixture("two-sheets-encrypted.xlsx")))
  tmp <- withr::local_tempfile(fileext = ".xlsx")

  # The FAT is sector 0, which starts at byte 512. Point every one of its
  # first entries at sector 0, so any chain through them cycles.
  x <- src
  for (i in 0:31) {
    x[512L + i * 4L + 1L] <- as.raw(0L)
    x[512L + i * 4L + 2L] <- as.raw(0L)
    x[512L + i * 4L + 3L] <- as.raw(0L)
    x[512L + i * 4L + 4L] <- as.raw(0L)
  }
  writeBin(x, tmp)
  result <- tryCatch(xlsx_read(tmp), zuxlsx_error = function(e) class(e)[1])
  expect_true(is.character(result))
})

test_that("the classifier reads what the decryptor reads: v4, BIFF5 and storages", {
  # The file's kind is decided by src/cfb.c, the reader decryption uses, so
  # a version 4 container is recognised, a BIFF5 "Book" is a legacy .xls,
  # and streams inside a storage count for neither -- without a password
  # and with one.
  skip_if_not_installed("zucrypt")
  plain <- workbook_bytes()

  v4 <- local_workbook_bytes(agile_encrypt(plain, "pw", spin_count = 10,
                                           version = 4L))
  expect_error(xlsx_read(v4), class = "zuxlsx_encrypted_error")
  expect_identical(xlsx_sheets(v4, password = "pw"), "Sheet1")

  book <- local_workbook_bytes(cfb_build(list(Book = as.raw(1:100))))
  expect_error(xlsx_read(book), class = "zuxlsx_unsupported_format_error")
  expect_identical(native_status(book), "format_xls")

  # Both streams, but under a storage rather than at the root.
  enc <- agile_encrypt(plain, "pw", spin_count = 10)
  stored <- cfb_build(list(
    Holder = raw(0),
    EncryptionInfo = cfb_stream_r(enc, "EncryptionInfo"),
    EncryptedPackage = cfb_stream_r(enc, "EncryptedPackage")
  ))
  holder <- cfb_entry_offset(stored, "Holder")
  stored[holder + 0x42 + 1L] <- as.raw(1L)        # a storage, not a stream
  stored <- put_u32(stored, holder + 0x48, 0xFFFFFFFF)  # no right sibling
  stored <- put_u32(stored, holder + 0x4C, 2)           # its child
  # Well formed -- the walk finds the storage -- with nothing at the root.
  expect_null(cfb_streams(stored, "EncryptionInfo")$EncryptionInfo)
  in_storage <- local_workbook_bytes(stored)
  for (pw in list(NULL, "pw")) {
    cond <- tryCatch(xlsx_read(in_storage, password = pw), error = identity)
    expect_s3_class(cond, "zuxlsx_unsupported_format_error")
    expect_false(inherits(cond, "zuxlsx_encrypted_error"))
  }
})
