# Reading stream contents out of a CFB container: src/cfb.c, design section
# 21c step 1.
#
# Two references, written independently of the C: helper-ole2.R's reader, and
# helper-cfb.R's writer, which produces spec-shaped containers the committed
# fixtures do not cover (version 4, DIFAT sectors, every stream size class).
# Then the hostile cases, which are the reason this is C that has to be
# careful: a workbook that arrives encrypted is a workbook somebody else
# produced.

test_that("the real fixture's streams match the R reader byte for byte", {
  path <- ole2_fixture("two-sheets-encrypted.xlsx")
  bytes <- readBin(path, "raw", file.size(path))
  got <- cfb_streams(bytes, c("EncryptionInfo", "EncryptedPackage"))
  # EncryptionInfo lives in the mini stream, EncryptedPackage in regular
  # sectors: both paths.
  expect_identical(got$EncryptionInfo, cfb_stream(path, "EncryptionInfo"))
  expect_identical(got$EncryptedPackage, cfb_stream(path, "EncryptedPackage"))
  expect_length(got$EncryptionInfo, 1441L)
})

test_that("streams of every size class come back exactly, in v3 and v4", {
  set.seed(20260929)
  streams <- list(
    empty = raw(0),
    tiny = as.raw(1:5),
    one_mini_sector = as.raw(sample(0:255, 64, TRUE)),
    below_cutoff = as.raw(sample(0:255, 4095, TRUE)),
    at_cutoff = as.raw(sample(0:255, 4096, TRUE)),
    several_sectors = as.raw(sample(0:255, 20001, TRUE))
  )
  for (version in c(3L, 4L)) {
    bytes <- cfb_build(streams, version)
    got <- cfb_streams(bytes, names(streams))
    for (name in names(streams)) {
      expect_identical(got[[name]], streams[[name]],
                       info = paste("v", version, name))
    }
    # The writer is checked too, against the separately written R reader.
    expect_identical(cfb_stream_r(bytes, "several_sectors"),
                     streams$several_sectors)
    expect_identical(cfb_stream_r(bytes, "below_cutoff"), streams$below_cutoff)
  }
})

test_that("a FAT past the header's 109 entries is followed into DIFAT sectors", {
  # 110 FAT sectors at 128 entries each: a stream of just over 7 MB.
  set.seed(1)
  streams <- list(large = as.raw(sample(0:255, 7.3e6, TRUE)),
                  small = as.raw(1:10))
  bytes <- cfb_build(streams, 3L)
  expect_gte(le_u32(bytes, 0x48), 1)            # DIFAT sectors in use
  got <- cfb_streams(bytes, names(streams))
  expect_identical(got$large, streams$large)
  expect_identical(got$small, streams$small)
})

test_that("names are compared case-insensitively, and only at the root", {
  path <- ole2_fixture("two-sheets-encrypted.xlsx")
  bytes <- readBin(path, "raw", file.size(path))
  got <- cfb_streams(bytes, c("ENCRYPTIONINFO", "encryptedpackage",
                              "Version", "DataSpaceMap", "\006DataSpaces",
                              "NoSuchStream", NA))
  expect_identical(got$ENCRYPTIONINFO, cfb_stream(path, "EncryptionInfo"))
  expect_identical(got$encryptedpackage, cfb_stream(path, "EncryptedPackage"))
  # These exist, but inside the \006DataSpaces storage, not at the root; a
  # reader scanning every entry would return them.
  expect_null(got$Version)
  expect_null(got$DataSpaceMap)
  # A storage is not a stream.
  expect_null(got[["\006DataSpaces"]])
  expect_null(got$NoSuchStream)
  expect_length(got, 7L)
})

test_that("something that is not a CFB container is refused as such", {
  zip <- readBin(system.file("extdata", "two-sheets.xlsx", package = "zuxlsx"),
                 "raw", 1e6)
  for (bytes in list(zip, raw(0), raw(511), as.raw(rep(0xD0, 600)))) {
    expect_error(cfb_streams(bytes, "EncryptionInfo"),
                 class = "zuxlsx_input_error")
  }
})

test_that("a truncated container gives an error or the right bytes, never others", {
  # Every length through the fixture. A stream the truncated buffer still
  # holds must come back exactly; one it does not must be an error, never a
  # short or padded copy.
  path <- ole2_fixture("two-sheets-encrypted.xlsx")
  src <- readBin(path, "raw", file.size(path))
  want <- cfb_streams(src, c("EncryptionInfo", "EncryptedPackage"))
  # Outcomes are collected and asserted once: an expectation per length costs
  # far more than the reads do.
  outcome <- vapply(seq(0, length(src) - 1), function(n) {
    got <- tryCatch(cfb_streams(src[seq_len(n)], names(want)),
                    zuxlsx_error = function(e) e)
    if (inherits(got, c("zuxlsx_integrity_error", "zuxlsx_input_error"))) {
      "refused"
    } else if (identical(got, want)) {
      "exact"
    } else {
      paste("wrong at", n)
    }
  }, character(1))
  # In this fixture every truncation is refused, since the last sector holds
  # stream data; "exact" is allowed for containers where that is not so.
  expect_identical(setdiff(outcome, c("refused", "exact")), character(0))
})

test_that("random damage to the tables produces a result or a condition", {
  # Header, FAT and directory: the bytes that steer the reader. A result may
  # legitimately differ -- a changed size is a different stream -- so this
  # asserts only that nothing but a list or a classed condition comes back.
  path <- ole2_fixture("two-sheets-encrypted.xlsx")
  src <- readBin(path, "raw", file.size(path))
  dir_at <- (le_u32(src, 0x30) + 1) * 512
  fat_at <- (le_u32(src, 0x4C) + 1) * 512
  targets <- c(0:511, fat_at + 0:511, dir_at + 0:1023)
  set.seed(42)
  outcome <- vapply(seq_len(1500), function(i) {
    bytes <- src
    at <- sample(targets, sample(1:4, 1))
    bytes[at + 1] <- as.raw(sample(0:255, length(at), TRUE))
    got <- tryCatch(cfb_streams(bytes, c("EncryptionInfo", "EncryptedPackage")),
                    zuxlsx_error = function(e) "condition")
    identical(got, "condition") || is.list(got)
  }, logical(1))
  expect_true(all(outcome))
})

test_that("a FAT chain that loops is malformed, not a hang", {
  streams <- list(big = as.raw(rep(1:255, 40)))       # 10200 bytes, 20 sectors
  bytes <- cfb_build(streams, 3L)
  start <- le_u32(bytes, cfb_entry_offset(bytes, "big") + 0x74)
  # Point the stream's first sector at itself in the FAT (sector 0).
  looped <- put_u32(bytes, 512 + start * 4, start)
  expect_error(cfb_streams(looped, "big"), class = "zuxlsx_integrity_error")

  # And the directory chain at itself: the directory is read to ENDOFCHAIN,
  # so this one is bounded only by the sector count.
  dir <- le_u32(bytes, 0x30)
  looped <- put_u32(bytes, 512 + dir * 4, dir)
  expect_error(cfb_streams(looped, "big"), class = "zuxlsx_integrity_error")
})

test_that("a miniFAT chain that loops, or runs off the mini stream, is malformed", {
  streams <- list(a = as.raw(rep(7, 300)), b = as.raw(rep(9, 200)))
  bytes <- cfb_build(streams, 3L)
  minifat <- (le_u32(bytes, 0x3C) + 1) * 512
  # a occupies mini sectors 0..4; make 0 point back at 0.
  expect_error(cfb_streams(put_u32(bytes, minifat, 0), "a"),
               class = "zuxlsx_integrity_error")
  # Or at a mini sector far past the end of the mini stream.
  expect_error(cfb_streams(put_u32(bytes, minifat, 100000), "a"),
               class = "zuxlsx_integrity_error")
  # b is untouched by either and still reads.
  expect_identical(cfb_streams(put_u32(bytes, minifat, 0), "b")$b, streams$b)
})

test_that("sibling ids that loop are walked once, and ids out of range are malformed", {
  streams <- list(first = as.raw(1:10), second = as.raw(11:20),
                  third = as.raw(21:30))
  bytes <- cfb_build(streams, 3L)
  second <- cfb_entry_offset(bytes, "second")

  # second's left sibling is first (id 1), which leads back to second: a
  # cycle. Everything is still found, exactly once.
  cyclic <- put_u32(bytes, second + 0x44, 1)
  got <- cfb_streams(cyclic, names(streams))
  expect_identical(got, streams)

  # A sibling id past the directory's end.
  expect_error(cfb_streams(put_u32(bytes, second + 0x48, 5000), "third"),
               class = "zuxlsx_integrity_error")
  # And one pointing at the root, which is nobody's sibling.
  expect_error(cfb_streams(put_u32(bytes, second + 0x48, 0), "third"),
               class = "zuxlsx_integrity_error")
})

test_that("two streams of the same name at the root are malformed, not a guess", {
  streams <- list(Alpha = as.raw(1:10), Bravo = as.raw(11:20))
  bytes <- cfb_build(streams, 3L)
  at <- cfb_entry_offset(bytes, "Bravo")
  # Rename Bravo to ALPHA -- the same name, case-insensitively.
  bytes[at + 1:10] <- as.raw(as.vector(rbind(utf8ToInt("ALPHA"), 0)))
  expect_error(cfb_streams(bytes, "Alpha"), class = "zuxlsx_integrity_error")
})

test_that("a stream size the container cannot back is refused before allocating", {
  streams <- list(big = as.raw(rep(3, 9000)), small = as.raw(1:100))
  for (version in c(3L, 4L)) {
    bytes <- cfb_build(streams, version)
    at <- cfb_entry_offset(bytes, "big")
    # More sectors than the chain has, in either sector size; more than the
    # whole container; and the largest a 32-bit size can say.
    for (size in c(9000 + 4096 * 2, length(bytes) + 1, 2^32 - 1)) {
      expect_error(cfb_streams(put_u32(bytes, at + 0x78, size), "big"),
                   class = "zuxlsx_integrity_error",
                   info = paste(version, size))
    }
    # A small stream claiming more mini sectors than its chain has.
    at <- cfb_entry_offset(bytes, "small")
    expect_error(cfb_streams(put_u32(bytes, at + 0x78, 4000), "small"),
                 class = "zuxlsx_integrity_error", info = version)
  }
})

test_that("version 3 ignores the size's high 32 bits; version 4 does not", {
  # [MS-CFB] 2.6.3: a v3 writer may leave garbage there, and a reader must
  # ignore it. In v4 the size is 64 bits, and this one is then impossible.
  streams <- list(s = as.raw(1:100))
  v3 <- cfb_build(streams, 3L)
  expect_identical(
    cfb_streams(put_u32(v3, cfb_entry_offset(v3, "s") + 0x7C, 0xDEADBEEF), "s")$s,
    streams$s
  )
  v4 <- cfb_build(streams, 4L)
  expect_error(
    cfb_streams(put_u32(v4, cfb_entry_offset(v4, "s") + 0x7C, 1), "s"),
    class = "zuxlsx_integrity_error"
  )
})

test_that("header fields the format fixes are checked", {
  bytes <- cfb_build(list(s = as.raw(1:10)), 3L)
  bad <- list(
    version_5 = { b <- bytes; b[0x1B:0x1C] <- as.raw(c(5, 0)); b },
    v3_with_v4_shift = { b <- bytes; b[0x1F:0x20] <- as.raw(c(12, 0)); b },
    byte_order = { b <- bytes; b[0x1D:0x1E] <- as.raw(c(0xFF, 0xFF)); b },
    mini_shift = { b <- bytes; b[0x21] <- as.raw(7); b },
    cutoff = put_u32(bytes, 0x38, 8192),
    fat_count = put_u32(bytes, 0x2C, 1e6),
    difat_count = put_u32(bytes, 0x48, 1e6),
    fat_sector = put_u32(bytes, 0x4C, 1e6),
    root_not_root = { b <- bytes; b[(le_u32(bytes, 0x30) + 1) * 512 + 0x43] <- as.raw(1); b }
  )
  for (name in names(bad)) {
    expect_error(cfb_streams(bad[[name]], "s"), class = "zuxlsx_integrity_error",
                 info = name)
  }
})

test_that("the encrypted-workbook fixtures decrypt from C-read streams", {
  # Step 1 feeding step 3: the same result as through the R reader.
  for (fixture in c("two-sheets-encrypted.xlsx", "two-sheets-encrypted-utf16.xlsx")) {
    path <- ole2_fixture(fixture)
    streams <- cfb_streams(readBin(path, "raw", file.size(path)),
                           c("EncryptionInfo", "EncryptedPackage"))
    params <- agile_params(streams$EncryptionInfo)
    password <- if (grepl("utf16", fixture)) "zü✓\U0001F511" else "zuxlsx"
    expect_identical(agile_decrypt(streams$EncryptedPackage, password, params),
                     agile_plaintext(), info = fixture)
  }
})
