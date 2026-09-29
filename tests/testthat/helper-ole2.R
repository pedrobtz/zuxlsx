# A minimal OLE2/CFB directory reader, in R.
#
# Two jobs. It checks that the fixtures tools/make-ole2.R writes are actually
# readable as CFB rather than merely starting with the right eight bytes --
# written from [MS-CFB] independently of the writer, so a misreading would
# have to be made twice in the same direction to go unnoticed.
#
# And it is the specification for the C the reader needs. Telling a
# password-protected .xlsx from a legacy .xls means getting exactly this far
# into the container and no further: header, FAT, directory, names. Everything
# below is bounds-checked the way that C will have to be, because these are
# hostile-input paths -- a workbook that arrives encrypted is a workbook
# somebody else produced.

SECTOR <- 512L
ENDOFCHAIN <- 0xFFFFFFFE

# Little-endian scalars. Read as doubles, because a sector number runs past
# what a signed 32-bit integer holds and R has no unsigned type.
le_u16 <- function(raw, at) {
  as.numeric(raw[at + 1L]) + 256 * as.numeric(raw[at + 2L])
}
le_u32 <- function(raw, at) {
  sum(as.numeric(raw[(at + 1L):(at + 4L)]) * c(1, 256, 65536, 16777216))
}

cfb_read <- function(path) {
  bytes <- readBin(path, "raw", file.size(path))
  expect_gte(length(bytes), SECTOR)

  magic <- as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
  expect_identical(bytes[1:8], magic)

  # A v3 container uses 512-byte sectors; v4 uses 4096. Only v3 is generated
  # here, and a reader that assumes the size rather than reading the shift is
  # a reader that misparses every v4 file it meets.
  sector_shift <- le_u16(bytes, 0x1E)
  expect_identical(sector_shift, 9)

  sector_at <- function(n) {
    from <- SECTOR + n * SECTOR
    # The bound is the point: a corrupt FAT entry pointing past the end of
    # the file is the first thing a hostile container does.
    expect_lte(from + SECTOR, length(bytes))
    bytes[(from + 1L):(from + SECTOR)]
  }

  first_dir <- le_u32(bytes, 0x30)
  fat_start <- le_u32(bytes, 0x4C)
  fat <- sector_at(fat_start)
  fat_entry <- function(n) le_u32(fat, n * 4L)

  # Walk the directory chain. Bounded by the number of sectors in the file,
  # so a FAT that loops back on itself terminates instead of hanging.
  max_sectors <- length(bytes) %/% SECTOR
  dir_bytes <- raw(0)
  sec <- first_dir
  seen <- 0L
  while (sec != ENDOFCHAIN && seen < max_sectors) {
    dir_bytes <- c(dir_bytes, sector_at(sec))
    sec <- fat_entry(sec)
    seen <- seen + 1L
  }
  expect_lt(seen, max_sectors)

  entries <- list()
  n_entries <- length(dir_bytes) %/% 128L
  for (i in seq_len(n_entries)) {
    at <- (i - 1L) * 128L
    type <- as.integer(dir_bytes[at + 0x42 + 1L])
    if (type == 0L) next                       # unallocated
    name_len <- le_u16(dir_bytes, at + 0x40)
    if (name_len < 2 || name_len > 64) next
    # UTF-16LE, and the recorded length includes the terminating null.
    chars <- dir_bytes[(at + 1L):(at + name_len - 2L)]
    name <- rawToChar(chars[seq(1L, length(chars), by = 2L)])
    entries[[length(entries) + 1L]] <- list(
      name = name,
      type = type,
      size = le_u32(dir_bytes, at + 0x78)
    )
  }
  entries
}

cfb_stream_names <- function(path) {
  vapply(cfb_read(path), function(e) e$name, character(1))
}

ole2_fixture <- function(name) {
  path <- test_path("fixtures", "ole2", name)
  skip_if(!file.exists(path), paste0(name, " fixture is missing"))
  path
}

# Reading stream *contents*, not just names -- the part design section 21c
# step 1 will put in C. Here it only has to supply the tests of step 3 with
# EncryptionInfo and EncryptedPackage, so it reads well-formed containers and
# stops on anything else rather than reporting it: [MS-CFB] 2.2 to 2.6, v3 and
# v4 sector sizes, the FAT from the header's DIFAT and any DIFAT sectors, the
# miniFAT, and the mini stream held in the root entry's chain.
cfb_stream <- function(path, name) {
  bytes <- readBin(path, "raw", file.size(path))
  sector_size <- 2^le_u16(bytes, 0x1E)
  mini_size <- 2^le_u16(bytes, 0x20)
  cutoff <- le_u32(bytes, 0x38)

  sector_at <- function(n) {
    from <- sector_size + n * sector_size
    if (from + sector_size > length(bytes)) stop("sector ", n, " is past the end")
    bytes[(from + 1):(from + sector_size)]
  }
  entries_u32 <- function(raw) {
    vapply(seq(0, length(raw) - 4, by = 4), function(at) le_u32(raw, at), 0)
  }

  # The FAT sectors: 109 in the header, then a chain of DIFAT sectors whose
  # last entry points at the next one.
  difat <- entries_u32(bytes[0x4D:0x200])
  next_difat <- le_u32(bytes, 0x44)
  for (i in seq_len(le_u32(bytes, 0x48))) {
    s <- entries_u32(sector_at(next_difat))
    difat <- c(difat, s[-length(s)])
    next_difat <- s[length(s)]
  }
  difat <- difat[seq_len(le_u32(bytes, 0x2C))]
  fat <- unlist(lapply(difat, function(s) entries_u32(sector_at(s))))

  chain <- function(start, table) {
    out <- numeric(0)
    while (start != ENDOFCHAIN) {
      if (length(out) > length(table)) stop("a chain loops")
      out <- c(out, start)
      start <- table[start + 1]
    }
    out
  }
  read_chain <- function(start) {
    unlist(lapply(chain(start, fat), sector_at))
  }

  dir <- read_chain(le_u32(bytes, 0x30))
  entries <- lapply(seq(0, length(dir) - 128, by = 128), function(at) {
    name_len <- le_u16(dir, at + 0x40)
    chars <- if (name_len >= 2) dir[(at + 1):(at + name_len - 2)] else raw(0)
    list(
      name = rawToChar(chars[seq_along(chars) %% 2L == 1L]),
      type = as.integer(dir[at + 0x43]),
      start = le_u32(dir, at + 0x74),
      size = le_u32(dir, at + 0x78)
    )
  })
  root <- entries[[1]]
  hit <- Filter(function(e) e$type == 2L && e$name == name, entries)
  if (length(hit) != 1L) stop("no single stream named ", name)
  e <- hit[[1]]

  if (e$size >= cutoff) {
    return(read_chain(e$start)[seq_len(e$size)])
  }
  minifat <- entries_u32(read_chain(le_u32(bytes, 0x3C)))
  ministream <- read_chain(root$start)[seq_len(root$size)]
  sectors <- chain(e$start, minifat)
  out <- unlist(lapply(sectors, function(s) {
    ministream[(s * mini_size + 1):((s + 1) * mini_size)]
  }))
  out[seq_len(e$size)]
}

# Base64, since base R has no decoder and the tests may use nothing else.
base64_decode <- function(text) {
  alphabet <- c(LETTERS, letters, 0:9, "+", "/")
  chars <- strsplit(gsub("[^A-Za-z0-9+/]", "", text), "")[[1]]
  values <- match(chars, alphabet) - 1L
  # Six bits per character, most significant first, regrouped as bytes; the
  # bits left over at the end are the padding's.
  bits <- as.vector(vapply(values, function(v) bitwAnd(bitwShiftR(v, 5:0), 1L),
                           integer(6)))
  bits <- bits[seq_len(length(bits) %/% 8L * 8L)]
  as.raw(colSums(matrix(bits, nrow = 8L) * 2L^(7:0)))
}

# The agile EncryptionInfo XML ([MS-OFFCRYPTO] 2.3.4.10), read into the list
# agile_decrypt() takes. Attribute extraction by pattern is enough for the
# files this is pointed at, which the tests choose; the C parser that replaces
# it will not have that luxury.
agile_params <- function(info) {
  expect_identical(info[1:8], as.raw(c(4, 0, 4, 0, 0x40, 0, 0, 0)))
  xml <- rawToChar(info[-(1:8)])

  element <- function(tag) {
    m <- regmatches(xml, regexpr(paste0("<", tag, "\\b[^>]*>"), xml))
    if (length(m) != 1L) stop("no <", tag, "> element")
    m
  }
  attr_of <- function(el, name) {
    m <- regmatches(el, regexec(paste0("\\s", name, "=\"([^\"]*)\""), el))[[1]]
    if (length(m) != 2L) stop("no ", name, " attribute")
    m[2]
  }
  cipher <- function(el) {
    list(
      cipher_algorithm = attr_of(el, "cipherAlgorithm"),
      cipher_chaining = attr_of(el, "cipherChaining"),
      hash_algorithm = attr_of(el, "hashAlgorithm"),
      salt_size = as.numeric(attr_of(el, "saltSize")),
      block_size = as.numeric(attr_of(el, "blockSize")),
      key_bits = as.numeric(attr_of(el, "keyBits")),
      hash_size = as.numeric(attr_of(el, "hashSize")),
      salt = base64_decode(attr_of(el, "saltValue"))
    )
  }

  key_data <- element("keyData")
  integrity <- element("dataIntegrity")
  encrypted_key <- element("p:encryptedKey")
  password <- c(cipher(encrypted_key), list(
    spin_count = as.numeric(attr_of(encrypted_key, "spinCount")),
    encrypted_verifier_hash_input =
      base64_decode(attr_of(encrypted_key, "encryptedVerifierHashInput")),
    encrypted_verifier_hash_value =
      base64_decode(attr_of(encrypted_key, "encryptedVerifierHashValue")),
    encrypted_key_value =
      base64_decode(attr_of(encrypted_key, "encryptedKeyValue"))
  ))
  list(
    key_data = cipher(key_data),
    encrypted_hmac_key = base64_decode(attr_of(integrity, "encryptedHmacKey")),
    encrypted_hmac_value = base64_decode(attr_of(integrity, "encryptedHmacValue")),
    password = password
  )
}

# The two streams of a real encrypted fixture, ready for agile_decrypt().
agile_fixture <- function(name) {
  path <- ole2_fixture(name)
  list(
    path = path,
    params = agile_params(cfb_stream(path, "EncryptionInfo")),
    package = cfb_stream(path, "EncryptedPackage")
  )
}

# The bytes both encrypted fixtures were made from.
agile_plaintext <- function() {
  path <- ole2_fixture("two-sheets-stored.xlsx")
  readBin(path, "raw", file.size(path))
}

# One bit changed, for tampering with a stream or a field.
flip <- function(x, at) {
  x[at] <- xor(x[at], as.raw(0x01))
  x
}

# An EncryptedPackage stream with its eight-byte length prefix rewritten. The
# length is a double so that values past 2^31 can be written.
with_length <- function(package, n) {
  package[1:8] <- as.raw(floor(n / 256^(0:7)) %% 256)
  package
}
