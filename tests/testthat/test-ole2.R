# OLE2 containers: what they are, and what the reader currently says.
#
# A password-protected .xlsx is not a damaged .xlsx. It is an OLE2/CFB
# container holding the encrypted package, which is also what a legacy .xls
# is -- so the eight-byte signature identifies the container and not which of
# the two it holds. src/zuxlsx.c says exactly that, and declines to guess.
#
# These tests pin the current behaviour before it changes, and pin the
# structural facts a better answer would be built on. Fixtures come from
# tools/make-ole2.R; see fixtures/ole2/MANIFEST.tsv.

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
  # This is the fact the reader does not use yet, and the reason a better
  # message is possible at all: the two formats are distinguishable without
  # decrypting anything, without a password, and without reading a byte of
  # ciphertext.
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
    expect_error(read_xlsx(ole2_fixture(name)),
                 class = "zuxlsx_unsupported_format_error", info = name)
  }
})

test_that("the message names encryption as a possibility", {
  # Pinning today's behaviour, which is deliberately non-committal: the
  # message offers both formats because the reader cannot yet tell them
  # apart. When it can, this test is the one that has to change, and it
  # should -- an encrypted workbook and an .xls need different advice.
  cond <- tryCatch(read_xlsx(ole2_fixture("encrypted-agile.xlsx")),
                   condition = function(e) e)
  expect_match(conditionMessage(cond), "OLE2")
  expect_match(conditionMessage(cond), "password-protected")
  expect_match(conditionMessage(cond), "cannot decrypt")

  # And says the same thing about a legacy .xls, which is the shortcoming.
  legacy <- tryCatch(read_xlsx(ole2_fixture("legacy.xls")),
                     condition = function(e) e)
  expect_identical(
    sub("^'[^']*'", "", conditionMessage(cond)),
    sub("^'[^']*'", "", conditionMessage(legacy))
  )
})

test_that("every entry point reports an OLE2 container the same way", {
  # read_xlsx() is not the only door in. A user calling xlsx_sheets() on an
  # encrypted workbook should not get a different story.
  path <- ole2_fixture("encrypted-agile.xlsx")
  for (fn in list(read_xlsx, xlsx_sheets, xlsx_cells)) {
    expect_error(fn(path), class = "zuxlsx_unsupported_format_error")
  }
})
