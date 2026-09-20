#!/usr/bin/env Rscript

## Generates the OLE2/CFB fixtures under tests/testthat/fixtures/ole2/.
##
##   Rscript tools/make-ole2.R            write the fixtures
##   Rscript tools/make-ole2.R --check    regenerate and compare, changing nothing
##
## Why generated rather than committed as opaque blobs: an encrypted workbook
## and a legacy .xls are both OLE2 containers, and telling them apart is the
## whole point of these fixtures. A binary nobody can regenerate is a fixture
## nobody can adjust when the reader needs a case it does not yet cover -- and
## these are hostile-input fixtures, so needing another case is the norm.
##
## Nothing here is encrypted. These files carry the *structure* an encrypted
## workbook has -- the container, the directory, the stream names -- and their
## stream contents are filler. That is enough to decide which of the two
## formats a file is, which is what the reader has to do before it can decide
## anything else. A genuinely Agile-encrypted fixture is a separate problem;
## see the note at the bottom of this file.
##
## Format reference: [MS-CFB], Compound File Binary File Format.

FIXTURES <- file.path("tests", "testthat", "fixtures", "ole2")

SECTOR <- 512L
ENDOFCHAIN <- 0xFFFFFFFE
FREESECT   <- 0xFFFFFFFF
FATSECT    <- 0xFFFFFFFD

u16 <- function(x) writeBin(as.integer(x), raw(), size = 2L, endian = "little")
u32 <- function(x) {
  ## writeBin's integer is signed, and sector values run past 2^31, so the
  ## four bytes are assembled by hand rather than fought with.
  x <- as.numeric(x)
  as.raw(c(x %% 256,
           (x %/% 256) %% 256,
           (x %/% 65536) %% 256,
           (x %/% 16777216) %% 256))
}
u64 <- function(x) c(u32(x), u32(0))

pad_to <- function(bytes, n) {
  stopifnot(length(bytes) <= n)
  c(bytes, raw(n - length(bytes)))
}

## A directory entry is 128 bytes. [MS-CFB] 2.6.1.
dir_entry <- function(name, type, start = ENDOFCHAIN, size = 0,
                      left = ENDOFCHAIN, right = ENDOFCHAIN,
                      child = ENDOFCHAIN) {
  ## The name is UTF-16LE including its terminating null, and the recorded
  ## length counts that null. Getting this wrong is the classic way a CFB
  ## reader sees a name one character short.
  chars <- utf8ToInt(name)
  stopifnot(all(chars < 0x10000), length(chars) <= 31L)
  utf16 <- as.raw(as.vector(rbind(chars %% 256, chars %/% 256)))
  name_bytes <- c(utf16, raw(2))

  c(
    pad_to(name_bytes, 64L),
    u16(length(name_bytes)),
    as.raw(type),        # 1 storage, 2 stream, 5 root
    as.raw(1L),          # colour: black
    u32(left), u32(right), u32(child),
    raw(16),             # CLSID
    u32(0),              # state bits
    raw(8), raw(8),      # creation, modification time
    u32(start),
    u64(size)
  )
}

## Builds a CFB file from a named list of raw vectors.
##
## Deliberately simple: every stream is written to its own chain of full
## sectors, and nothing uses the mini stream. The mini stream exists to pack
## streams under 4096 bytes together, and avoiding it costs a few kilobytes of
## fixture and removes a whole second allocation table from code that only
## needs to read names.
build_cfb <- function(streams) {
  stopifnot(length(streams) <= 8L)

  ## Sector 0 is the FAT, sector 1 the directory, streams follow.
  fat_sector <- 0L
  dir_sector <- 1L
  next_free <- 2L

  chains <- list()
  data_sectors <- list()
  for (nm in names(streams)) {
    payload <- streams[[nm]]
    n <- max(1L, ceiling(length(payload) / SECTOR))
    padded <- pad_to(payload, n * SECTOR)
    chains[[nm]] <- list(start = next_free, n = n, size = length(payload))
    for (i in seq_len(n)) {
      data_sectors[[length(data_sectors) + 1L]] <-
        padded[((i - 1L) * SECTOR + 1L):(i * SECTOR)]
    }
    next_free <- next_free + n
  }
  total_sectors <- next_free

  ## The FAT: one entry per sector, each holding the next sector in that
  ## chain. One FAT sector holds 128 entries, which caps this at 128 sectors
  ## -- 64 KiB of fixture, and the stopifnot says so rather than producing a
  ## file that is quietly truncated.
  stopifnot(total_sectors <= SECTOR / 4L)
  fat <- rep(FREESECT, SECTOR / 4L)
  fat[fat_sector + 1L] <- FATSECT
  fat[dir_sector + 1L] <- ENDOFCHAIN
  for (nm in names(chains)) {
    ch <- chains[[nm]]
    for (i in seq_len(ch$n)) {
      sec <- ch$start + i - 1L
      fat[sec + 1L] <- if (i == ch$n) ENDOFCHAIN else sec + 1L
    }
  }

  ## The directory. Entry 0 is the root; the rest are the streams, chained as
  ## a flat right-leaning tree, which is legal and is what matters for a
  ## reader that walks entries rather than the red-black tree.
  entries <- list(dir_entry("Root Entry", type = 5L, child = 1L))
  ids <- seq_along(streams)
  for (i in ids) {
    nm <- names(streams)[i]
    ch <- chains[[nm]]
    entries[[i + 1L]] <- dir_entry(
      nm, type = 2L, start = ch$start, size = ch$size,
      right = if (i < length(ids)) i + 1L else ENDOFCHAIN
    )
  }
  dir_bytes <- pad_to(unlist(entries), SECTOR)

  header <- c(
    as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)),
    raw(16),                 # CLSID
    u16(0x003E),             # minor version
    u16(0x0003),             # major version: 512-byte sectors
    u16(0xFFFE),             # little endian
    u16(9),                  # sector shift: 2^9 = 512
    u16(6),                  # mini sector shift: 2^6 = 64
    raw(6),                  # reserved
    u32(0),                  # directory sector count (0 in v3)
    u32(1),                  # FAT sector count
    u32(dir_sector),
    u32(0),                  # transaction signature
    u32(4096),               # mini stream cutoff
    u32(ENDOFCHAIN),         # first mini FAT sector: none
    u32(0),                  # mini FAT sector count
    u32(ENDOFCHAIN),         # first DIFAT sector: none
    u32(0),                  # DIFAT sector count
    u32(fat_sector),         # DIFAT[0]
    unlist(lapply(seq_len(108L), function(i) u32(FREESECT)))
  )
  header <- pad_to(header, SECTOR)

  fat_bytes <- unlist(lapply(fat, u32))
  c(header, fat_bytes, dir_bytes, unlist(data_sectors))
}

## --- the fixtures ---------------------------------------------------------

filler <- function(n, seed) {
  set.seed(seed)
  as.raw(sample.int(256L, n, replace = TRUE) - 1L)
}

fixtures <- function() {
  list(
    ## What a password-protected .xlsx actually is: an OLE2 container holding
    ## the encryption description and the encrypted package. [MS-OFFCRYPTO].
    ## The names are the whole signal -- a reader can identify the format from
    ## the directory without touching a byte of ciphertext.
    "encrypted-agile.xlsx" = list(
      EncryptionInfo = c(
        ## The eight-byte prefix [MS-OFFCRYPTO] 2.3.4.10 puts in front of the
        ## descriptor: version 4.4, flags 0x40. That combination is what
        ## identifies Agile encryption rather than the older Standard scheme,
        ## and it is the first thing a reader would look at.
        ##
        ## Built from raw rather than written into a string literal, because
        ## R strings cannot carry an embedded null and three of these bytes
        ## are one.
        u16(4), u16(4), u32(64),
        ## A plausible descriptor. Nothing parses it yet; it is here so the
        ## fixture is the right shape when something does.
        charToRaw(paste0(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
          '<encryption xmlns="http://schemas.microsoft.com/office/2006/encryption">',
          '<keyData saltSize="16" blockSize="16" keyBits="256" hashSize="64" ',
          'cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" ',
          'hashAlgorithm="SHA512"/>',
          '</encryption>'
        ))
      ),
      EncryptedPackage = c(u64(65536), filler(8192L, 1L))
    ),

    ## A legacy .xls: the same container, a completely different payload. The
    ## reader has to say something different about this one, and today it
    ## cannot tell them apart.
    "legacy.xls" = list(
      Workbook = filler(8192L, 2L)
    ),

    ## An OLE2 container that is neither: no recognisable stream at all. The
    ## honest answer here is still "OLE2, and not a workbook we read", which
    ## is what the reader must not get wrong while reaching for a better
    ## message for the two above.
    "unknown-ole2.bin" = list(
      SomethingElse = filler(4096L, 3L)
    )
  )
}

write_fixtures <- function(dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  all <- fixtures()
  for (nm in names(all)) {
    writeBin(build_cfb(all[[nm]]), file.path(dir, nm))
  }
  manifest <- data.frame(
    file = names(all),
    streams = vapply(all, function(x) paste(names(x), collapse = ","), ""),
    describes = c("password-protected xlsx (Agile), structure only",
                  "legacy BIFF8 .xls",
                  "OLE2 container that is neither"),
    generator = "tools/make-ole2.R",
    row.names = NULL
  )
  utils::write.table(manifest, file.path(dir, "MANIFEST.tsv"),
                     sep = "\t", quote = FALSE, row.names = FALSE)
  invisible(names(all))
}

main <- function(args) {
  check <- "--check" %in% args
  if (!check) {
    written <- write_fixtures(FIXTURES)
    message(sprintf("wrote %d fixtures to %s", length(written), FIXTURES))
    return(invisible(TRUE))
  }

  tmp <- tempfile("ole2-check-")
  write_fixtures(tmp)
  ok <- TRUE
  for (f in list.files(tmp)) {
    a <- file.path(FIXTURES, f)
    if (!file.exists(a)) {
      message("MISSING ", a); ok <- FALSE; next
    }
    if (!identical(readBin(a, "raw", file.size(a)),
                   readBin(file.path(tmp, f), "raw",
                           file.size(file.path(tmp, f))))) {
      message("DIFFERS ", a); ok <- FALSE
    }
  }
  unlink(tmp, recursive = TRUE)
  if (!ok) {
    stop("fixtures do not match this generator; re-run without --check",
         call. = FALSE)
  }
  message("fixtures match the generator.")
  invisible(TRUE)
}

main(commandArgs(trailingOnly = TRUE))

## A note on what is NOT here, and where it went.
##
## None of the fixtures written above is really encrypted, and no test should
## claim otherwise. They carry the structure -- container, directory, stream
## names -- which is all the reader needs to tell a password-protected .xlsx
## from a legacy .xls, and that is the question it currently gets wrong.
##
## Genuinely encrypted fixtures now exist beside them, produced by
## msoffcrypto-tool rather than by this script: two-sheets-encrypted.xlsx and
## the plaintext it came from. They are committed as binaries because Agile
## encryption draws a random salt and a random content key, so there is no
## byte-reproducible version to generate -- and a fixed-seed one would be less
## like the files this package will meet, not more.
##
## See fixtures/ole2/README.md for how to reproduce them, and for the
## msoffcrypto-tool 6.0.0 defect that makes the plaintext size load-bearing:
## below 4081 bytes it writes a corrupt container and exits 0.
