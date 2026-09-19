# zuxlsx Design

## 1. Purpose

`zuxlsx` is a lightweight R package for reading `.xlsx` workbooks using a small C stack:

- **xlsxio** for XLSX / OOXML workbook and worksheet logic
- **zuxml** for XML parsing, backed by vendored **Expat**
- **zukomp** for ZIP and DEFLATE support, backed by vendored **miniz**

The package is intended to remain small, predictable, dependency-light, and suitable for streaming cell and row reads.

The key design constraint is:

> `zuxlsx` uses `zuxml` and `zukomp` through `LinkingTo` only.

There is no R-level `Imports:` dependency on either package and no use of `R_GetCCallable()` for the core parser/compression path.

---

## 2. High-level architecture

```text
                         zuxlsx
                           |
                    XLSX / OOXML layer
                         xlsxio
                           |
              +------------+------------+
              |                         |
              v                         v
            zuxml                    zukomp
          Expat-backed              miniz-backed
          XML parsing               ZIP / DEFLATE
```

The XLSX format is a ZIP container containing XML parts. This maps naturally onto the existing packages:

```text
.xlsx
  |
  v
zukomp / miniz
  |
  +-- xl/workbook.xml
  +-- xl/_rels/workbook.xml.rels
  +-- xl/sharedStrings.xml
  +-- xl/styles.xml
  +-- xl/worksheets/sheet*.xml
             |
             v
        zuxml / Expat
             |
             v
         xlsxio logic
             |
             v
        rows / cells
             |
             v
          R objects
```

---

## 3. Dependency model

`DESCRIPTION`:

```text
LinkingTo:
    zuxml,
    zukomp
```

No `Imports:` entry is required for the native dependency path.

`LinkingTo` provides access to installed headers from:

```text
zuxml/inst/include/
zukomp/inst/include/
```

The native implementations are then linked into `zuxlsx` at installation time using native libraries exposed by those packages.

This design deliberately avoids:

```text
Imports: zuxml, zukomp
R_GetCCallable()
dynamic lookup of zuxml.so / zukomp.so
```

The desired model is static/native build-time reuse.

---

## 4. Native library exposure

### zuxml

`zuxml` should expose:

```text
zuxml/
├── inst/
│   ├── include/
│   │   ├── expat.h
│   │   ├── expat_external.h
│   │   └── zuxml/
│   │       └── ...
│   └── lib/
│       └── libzuxml.a
```

`libzuxml.a` should contain the Expat implementation needed by downstream packages.

The public headers must make the Expat API usable directly by xlsxio, including functions such as:

```c
XML_ParserCreate();
XML_SetElementHandler();
XML_SetCharacterDataHandler();
XML_Parse();
XML_ParseBuffer();
XML_GetBuffer();
XML_ParserFree();
```

xlsxio needs the Expat API at compile time, but it does not need Expat source files in the `zuxlsx` source tree.

### zukomp

`zukomp` should similarly expose:

```text
zukomp/
├── inst/
│   ├── include/
│   │   ├── miniz.h
│   │   ├── miniz_common.h
│   │   ├── miniz_tdef.h
│   │   ├── miniz_tinfl.h
│   │   ├── miniz_zip.h
│   │   └── zukomp/
│   │       └── ...
│   └── lib/
│       └── libzukomp.a
```

`libzukomp.a` should contain the miniz implementation.

The ZIP reader API required by `zuxlsx` includes operations equivalent to:

```c
mz_zip_reader_init_file();
mz_zip_reader_end();
mz_zip_reader_locate_file();
mz_zip_reader_file_stat();
mz_zip_reader_extract_iter_new();
mz_zip_reader_extract_iter_read();
mz_zip_reader_extract_iter_free();
```

### Status, 2026-09-17

**Done: both merged on 2026-09-18, and `zuxlsx` builds against them.** What
follows is kept because it records why two v1 packages were widened. As
shipped at v1, neither package exposed any of the above:

- `zuxml/inst/include/` holds only `zuxml.h`; there is no `expat.h`, no
  `expat_external.h`, and no `inst/lib/libzuxml.a`. The installed header is
  deliberately standalone C99 and names no Expat type.
- `zukomp/inst/include/` holds only `zukomp.h` and `zukomp-r.h`, and
  `zukomp/src/Makevars` compiles miniz with `MINIZ_NO_ARCHIVE_APIS`,
  `MINIZ_NO_ARCHIVE_WRITING_APIS` and `MINIZ_NO_STDIO`. The ZIP reader listed
  above is compiled out entirely, and `zukomp`'s own `test-abi.R` asserts that
  no `mz_zip_*` symbol is exported.
- Both packages document the opposite integration contract from section 3:
  `Imports:` + `LinkingTo:`, resolving a versioned function table through
  `R_GetCCallable()` (`zuxml_api_get()`, `zukomp_api()`).

**Decision: widen the siblings to match this section, rather than changing
this section.** Both changes are merged:

- pedrobtz/zuxml#7 (merged 2026-09-18) -- ships `inst/lib/libzuxml.a` plus
  `expat.h` and `expat_external.h`.
- pedrobtz/zukomp#10 (merged 2026-09-18) -- ships `inst/lib/libzukomp.a` with
  miniz's ZIP reader, plus `miniz.h`. It compiles `miniz.c` a second time
  rather than widening the trim, so `zukomp.so` still exports no `mz_zip_*`
  symbol and its ABI test is untouched.

`zuxlsx` therefore has a `configure` + `src/Makevars.in` pair, and
`DESCRIPTION` pins neither package to a branch. `Remotes:` still names both
repositories, because they are not on CRAN; it must be dropped before any CRAN
submission.

Verified against the vendored reader in this repo: xlsxio compiles against
those installed headers, links both archives, and reads the fixtures in
`tests/testthat/sheets/` -- inline strings, UTF-8 sheet names and a workbook
with no `sharedStrings.xml` part.

What each package had to do:

| Package | Change |
| --- | --- |
| `zuxml` | Install `expat.h` and `expat_external.h`; ship `inst/lib/libzuxml.a` containing the Expat implementation. The whole Expat API in this section must be usable directly, including `XML_StopParser`/`XML_ResumeParser`, which xlsxio's row/cell and sheet-list iterators depend on. Confirmed present in the archive. |
| `zukomp` | Drop `MINIZ_NO_ARCHIVE_APIS` (reader at least) and `MINIZ_NO_STDIO`, since `mz_zip_reader_init_file()` needs file I/O; install `miniz.h`; ship `inst/lib/libzukomp.a`. `MINIZ_NO_TIME` also has to go, or `mz_zip_archive_file_stat.m_time` is miniz's `m_padding` instead. The `test-abi.R` assertion forbidding `mz_zip_*` needs no relaxing: the second build keeps it true. |

Note this widens two packages that are already at v1 and whose current design
treats those surfaces as deliberately hidden -- so it is a public-surface
change in both, not just a build tweak. zukomp#10 keeps that cost off the
shared object by compiling miniz twice: the ZIP code exists only inside the
static archive, which nothing in zukomp itself links. `MINIZ_NO_ZLIB_COMPATIBLE_NAMES` must
stay: without it `miniz.h` `#define`s `compress`, `crc32` and `adler32` over
every translation unit that also sees R's headers.

---

## 5. Why miniz instead of minizip

xlsxio normally supports ZIP access through libraries such as minizip or libzip.

`zukomp`, however, vendors **miniz**, not minizip.

This is not a functionality problem.

miniz provides both:

```text
DEFLATE / zlib-style compression
+
ZIP archive reading and writing
```

Therefore no additional ZIP library is required.

The only required work is adapting xlsxio's ZIP backend from the minizip API to the miniz ZIP API.

Conceptually:

```text
xlsxio minizip backend          zuxlsx miniz backend

unzOpen()                  ->   mz_zip_reader_init_file()
unzLocateFile()            ->   mz_zip_reader_locate_file()
unzOpenCurrentFile()       ->   create extraction iterator
unzReadCurrentFile()       ->   mz_zip_reader_extract_iter_read()
unzCloseCurrentFile()      ->   mz_zip_reader_extract_iter_free()
unzClose()                 ->   mz_zip_reader_end()
```

The adaptation should be isolated behind a small xlsxio-compatible ZIP abstraction rather than spread throughout the reader.

### Status, 2026-09-17: done, and vendored

This adaptation already exists and is committed. `tools/patches/xlsxio/0001-miniz-zip-backend.patch`
adds a `USE_MINIZ` backend beside xlsxio's existing `USE_MINIZIP` /
`USE_MINIZIP_NG` / libzip ones, exactly along the mapping above, and
`src/vendor/xlsxio/` is 0.2.36 with it applied. It came from the
`utopp/pkg-xlsx` prototype, where the same combination is known to read
workbooks end to end.

It is *not* isolated behind a separate abstraction as this section asks for:
it is `#if defined(USE_MINIZ)` arms inline in `xlsxio_read.c`, alongside the
other backends. That is what keeps the patch upstreamable and re-appliable to
a future xlsxio release, which is worth more here than the isolation.

There is a **second** patch, `0002-namespace-insensitive-relationship-id.patch`,
unrelated to ZIP: it looks a worksheet's relationship id up as `id` rather than
the literal `r:id`, so a workbook that binds the OOXML relationships namespace
to a different prefix still resolves. The two patches applied in order to
pristine 0.2.36 reproduce `src/vendor/xlsxio/` byte for byte, and
`tools/vendor/verify` checks that claim offline against the manifest, the
checksums and `inst/COPYRIGHTS`.

One detail worth knowing: `mz_zip_reader_extract_iter_read()` returns
`size_t`, so minizip's `buflen >= 0` loop condition is vacuous for it. The
patch moves the read into the loop body; a short read still ends the stream
through the existing `done` test.

---

## 6. xlsxio integration

Only the XLSX reader portion of xlsxio is required initially.

The package should vendor the relevant xlsxio reader code and modify its build configuration so that:

```text
XML implementation  -> zuxml / Expat
ZIP implementation  -> zukomp / miniz
```

No duplicate copy of Expat or miniz should be vendored inside `zuxlsx`.

Suggested source layout:

```text
zuxlsx/
├── DESCRIPTION
├── NAMESPACE
├── R/
│   ├── read-xlsx.R
│   ├── sheets.R
│   └── cells.R
│
├── src/
│   ├── Makevars
│   ├── Makevars.win
│   ├── init.c
│   ├── zu_xlsx.c
│   ├── zu_xlsx_columns.c
│   ├── zu_xlsx_types.c
│   │
│   ├── xlsxio/
│   │   ├── xlsxio_read.c
│   │   ├── xlsxio_read.h
│   │   └── ...
│   │
│   └── xlsxio_miniz.c
│
└── tests/
    └── testthat/
```

`xlsxio_miniz.c` should be the only compatibility layer required for replacing minizip.

---

## 7. Build and linking flow

Compilation:

```text
zuxlsx source
   |
   +-- #include <expat.h>
   |       ^
   |       |
   |    LinkingTo: zuxml
   |
   +-- #include <miniz.h>
           ^
           |
        LinkingTo: zukomp
```

Linking:

```text
xlsxio objects
zuxlsx objects
      |
      +-- libzuxml.a
      |
      +-- libzukomp.a
      |
      v
   zuxlsx.so
```

The final `zuxlsx` shared object therefore contains the native code it needs:

```text
zuxlsx.so
├── zuxlsx R/C interface
├── xlsxio reader
├── Expat implementation
└── miniz implementation
```

There is no runtime dependency on locating or dynamically linking `zuxml.so` or `zukomp.so`.

---

## 8. Makevars strategy

The exact mechanism should remain simple and portable.

A build helper provided by each dependency is desirable.

For example:

```r
zuxml::pkgconfig("PKG_LIBS")
zukomp::pkgconfig("PKG_LIBS")
```

would normally imply an R-level dependency, so for a strict `LinkingTo`-only design it is preferable for the native library locations to be discoverable directly from the installed package structure.

Conceptually:

```make
ZUXML_PATH = <installed zuxml path>
ZUKOMP_PATH = <installed zukomp path>

PKG_LIBS += $(ZUXML_PATH)/lib/libzuxml.a
PKG_LIBS += $(ZUKOMP_PATH)/lib/libzukomp.a
```

The implementation should avoid embedding absolute dependency paths into the resulting runtime binary.

Static linking is preferred specifically because it removes runtime loader dependence on the installation locations of `zuxml` and `zukomp`.

---

## 9. Reading pipeline

A worksheet read should operate as a streaming pipeline:

```text
open XLSX
   |
   v
miniz opens ZIP archive
   |
   v
locate worksheet XML
   |
   v
decompress chunk
   |
   v
Expat buffer
   |
   v
XML_ParseBuffer()
   |
   v
xlsxio callbacks
   |
   +-- row start
   +-- cell reference
   +-- cell type
   +-- value
   +-- row end
   |
   v
R column builders
```

This avoids fully materializing worksheet XML in memory.

A typical chunk size can be in the range:

```text
32 KiB - 128 KiB
```

and should be benchmarked rather than hard-coded prematurely.

---

## 10. Shared strings

The XLSX shared-string table is a significant design consideration.

A first implementation can follow xlsxio and load `xl/sharedStrings.xml` into memory.

This gives a simpler initial reader:

```text
sharedStrings.xml
       |
       v
vector / table of strings
       |
sheet cell type "s"
       |
       v
integer index -> string
```

This should be documented as the principal non-streaming component of the first version.

Later versions may investigate:

- lazy shared-string indexing
- compact offsets into a single backing buffer
- on-demand lookup
- temporary-file-backed indexes for extremely large workbooks

The initial implementation should favor simplicity and correctness.

---

## 11. Styles and dates

Excel dates are stored as numeric values plus style information.

Therefore correct date/datetime interpretation requires reading:

```text
xl/styles.xml
```

The reader should separate:

```text
raw cell value
cell storage type
number format / style
interpreted R type
```

An initial implementation can support:

- character
- double
- integer-like numeric values represented as double
- logical
- date
- POSIXct / datetime
- blank / missing

Care must be taken with Excel's 1900 and 1904 date systems.

### Status, 2026-09-19: formats are read, the epoch is not applied yet

`xl/styles.xml` is parsed as of vendored patch 0003, and a cell's style index
resolves to "is this number a date or a time" through `cellXfs` and `numFmts`.
`xlsx_cells()` reports such a cell as type `date` and hands back the serial
number unchanged.

The conversion to an R `Date` or `POSIXct` is deliberately **not** done there.
The epoch is a property of the workbook -- `workbookPr/@date1904` -- not of the
cell, and that attribute is not read yet. Converting with a hard-coded 1900
epoch would silently shift every date in a 1904 workbook by four years, which
is worse than handing back a number the caller can see is unconverted.

Reading `date1904` and applying it belongs with `read_xlsx()`, which is where
a column acquires a type.

---

## 12. Proposed R API

Initial high-level API:

```r
read_xlsx(
  path,
  sheet = 1,
  col_names = TRUE,
  range = NULL
)
```

Additional lightweight APIs:

```r
xlsx_sheets(path)

xlsx_cells(
  path,
  sheet = 1
)

xlsx_rows(
  path,
  sheet = 1
)
```

Possible low-level streaming API:

```r
xlsx_read_cells(
  path,
  sheet = 1,
  callback
)
```

The first release should keep the public API deliberately narrow.

### Status, 2026-09-19: `xlsx_sheets()` and `xlsx_cells()`

`xlsx_cells()` is implemented, returning one row per cell with `row`, `col`,
`type`, `value` and `number`. `read_xlsx()`, `xlsx_rows()` and
`xlsx_read_cells()` are not.

`xlsx_cells()` was built before `read_xlsx()` on purpose. It needs only the
cell event model of section 13, whereas `read_xlsx()` additionally needs the
column builders of section 14 and the epoch handling of section 11, so
building it first would have coupled three unproven things. It also makes the
`valid/` corpus assertable for the first time: until there was a way to read a
cell, a fixture could only be checked for opening at all.

---

## 13. Cell reader abstraction

The internal reader should expose a simple cell event model independent of xlsxio internals.

Example:

```c
typedef enum {
    ZU_XLSX_BLANK,
    ZU_XLSX_STRING,
    ZU_XLSX_NUMBER,
    ZU_XLSX_LOGICAL,
    ZU_XLSX_DATE,
    ZU_XLSX_DATETIME,
    ZU_XLSX_ERROR
} zu_xlsx_type;

typedef struct {
    uint32_t row;
    uint32_t col;
    zu_xlsx_type type;

    const char *text;
    size_t text_len;

    double number;
    int logical;
} zu_xlsx_cell;
```

This provides a stable boundary between:

```text
xlsxio / OOXML parsing
```

and:

```text
R data-frame construction
```

### Status, 2026-09-19: implemented, in C rather than as a public header

`zu_cell_type` and the classification live in `src/zuxlsx.c` as an enum and
`classify_cell()`. The struct of section 13 is not materialised per cell:
cells accumulate into parallel arrays -- row, column, type, text, number --
which is the same boundary with the layout section 14 wants, and avoids one
allocation per cell.

Populating it needed vendored patch 0003. xlsxio reported every cell as text,
read the `t=` attribute only to test for `"s"`, and located `xl/styles.xml`
without ever opening it, so neither the OOXML type nor the number format was
reachable through its API. The patch adds
`xlsxioread_sheet_last_cell_type()` and `xlsxioread_sheet_last_cell_is_date()`
without changing any existing signature.

One boundary detail worth keeping: `xlsxioread_sheet_next_cell()` returns
`NULL` for end of row, and a blank cell as a non-`NULL` empty string. Treating
`NULL` as a value does not terminate the row.

---

## 14. Column building

For `read_xlsx()`, avoid constructing one R object per cell where possible.

Preferred pipeline:

```text
cell events
   |
   v
column builders
   |
   +-- numeric buffer
   +-- logical buffer
   +-- string references
   +-- missingness
   |
   v
final R vectors
   |
   v
data.frame
```

Type inference should preferably happen over a controlled sample or through progressive promotion:

```text
logical
   ->
numeric
   ->
character
```

with explicit handling for date/datetime columns.

---

## 15. Error handling

Errors should be surfaced as structured R conditions where practical.

Important error classes include:

```text
zuxlsx_error
zuxlsx_zip_error
zuxlsx_xml_error
zuxlsx_ooxml_error
zuxlsx_sheet_error
zuxlsx_type_error
```

### Status, 2026-09-18: the mechanism exists, four classes of it

`R/conditions.R` implements the nesting -- every class above is followed by
`zuxlsx_error`, so `tryCatch(zuxlsx_error = ...)` catches all of them -- and
conditions carry the offending `path`. Implemented so far:

| Class | Raised when |
| --- | --- |
| `zuxlsx_input_error` | `path` is not one usable string, is missing, or is a directory |
| `zuxlsx_zip_error` | the file will not open as a ZIP archive |
| `zuxlsx_ooxml_error` | the archive opened but declares no worksheets |
| `zuxlsx_memory_error` | an allocation failed while reading |
| `zuxlsx_sheet_error` | the workbook opened, but has no such worksheet |

`zuxlsx_input_error` and `zuxlsx_memory_error` are additions to the list
above. `zuxlsx_sheet_error` arrived with `xlsx_cells()`, as expected.
`zuxlsx_xml_error` and `zuxlsx_type_error` are still unraised: a malformed
part currently surfaces as `zuxlsx_ooxml_error`, and nothing yet promotes a
cell to a column type that could conflict.

Note that the worksheet name is checked in R against `xlsx_sheets()` rather
than left to the native layer. Opening a worksheet that does not exist yields
a handle reporting no rows, so an unknown name would otherwise be
indistinguishable from an empty sheet.

The C layer never calls `Rf_error()`. Both entry points return a
`(status, value)` pair and `zuxlsx_unwrap()` turns a non-`"ok"` status into the
condition, which is what keeps the longjmp away from the ZIP handle and the
parser. An unrecognised status is itself an error rather than a `NULL`.

Useful context should include:

- file name
- ZIP member
- worksheet
- XML line/column where available
- cell reference where available

Malformed XLSX input should never cause undefined behavior or process crashes.

---

## 16. Security and robustness

XLSX is an untrusted ZIP + XML container.

The reader should explicitly defend against:

- truncated ZIP archives
- corrupt central directories
- duplicate ZIP entries
- extreme uncompressed sizes
- compression bombs
- malformed XML
- invalid relationships
- missing workbook parts
- invalid shared-string indices
- extreme row/column indices
- integer overflow
- pathological XML nesting
- excessively large individual strings

Potential limits should be configurable internally and documented.

### Status, 2026-09-19: eight of thirteen are covered by tests

`test-hostile.R` and `test-malformed.R` cover truncated archives, corrupt
central directories, duplicate entries, extreme uncompressed sizes, malformed
XML, missing workbook parts, pathological nesting and excessively large
strings -- see 17.4b for what each one established.

Not yet covered, because they need the reading API to be reachable at all:
invalid relationships beyond a dangling `r:id`, invalid shared-string indices,
extreme row and column indices, and integer overflow in cell references.
Compression bombs are also untested: every hand-built archive here uses stored
entries, so a real bomb needs a DEFLATE writer the test helper does not have.

No configurable limits exist yet. Nothing in the reader caps a part size, a
string length or a sheet count; the defenses that hold today come from Expat's
and miniz's own behavior rather than from a policy this package sets.

---

## 17. Test strategy

There is no single canonical XLSX equivalent of `JSONTestSuite`.

Testing should combine several corpora. Four sources, in the order they earn
their keep:

1. **SheetJS `test_files`** -- the best ready-made broad XLSX corpus, with
   formula-heavy workbooks, hidden sheets, dates, and compatibility oddities.
2. **Apache POI `test-data`** -- a regression corpus accumulated over years
   from real interoperability bugs.
3. **xlsxio's own fixtures** -- narrow, but they exercise precisely the reader
   being adapted here, so a failure is unambiguous.
4. **Generated mutation cases** -- the only source that can target the seam
   this package actually owns, which is miniz to Expat to xlsxio.

ECMA-376 / ISO/IEC 29500 defines what a conforming consumer should accept but
states that it does not include a test suite, so there is no official
conformance corpus to fall back on. That is what makes 17.4 load-bearing
rather than supplementary.

**Constraint on 1 and 2.** Both are large external archives under Apache-2.0,
and neither can be vendored wholesale: a CRAN tarball is a few megabytes, and
Apache-2.0 files in an MIT package carry notice obligations that
`inst/COPYRIGHTS` would have to absorb per file. They therefore enter as
curated subsets, chosen for cases nothing else covers, or stay out of the
package entirely and run from CI against a fetched archive. That decision is
open; the choice is between a few dozen committed files with full provenance,
and a CI-only job that tests more but does not travel with the package.

### 17.1 xlsxio fixtures

Use xlsxio's own fixtures and tests first because they directly exercise the upstream reader logic being adapted.

### 17.2 SheetJS test files

Use a curated subset of the SheetJS workbook corpus for broad interoperability and unusual XLSX structures.

Relevant cases include:

- shared strings
- inline strings
- formulas
- sparse sheets
- hidden sheets
- unusual styles
- Unicode
- dates
- malformed files
- large files

### 17.3 Apache POI test data

Apache POI has a long-lived collection of OOXML regression files and compatibility fixtures.

A curated subset can provide valuable cases that originated from real-world workbook bugs.

### 17.3b Status, 2026-09-18

Seven readxl interoperability workbooks are committed under
`tests/testthat/sheets/`, with per-file provenance and checksums in
`MANIFEST.tsv` there; each was verified byte for byte against readxl at commit
`47f8aeac`. `tools/vendor/verify` checks them alongside the vendored source, and
a test walks the manifest so that a fixture added without its own test still
has to open. The generated corpus below is still to be built.

### 17.4 Generated fixtures

Maintain small deterministic workbooks generated specifically for `zuxlsx`,
in four categories rather than three: splitting `unusual/` into
`unusual-valid/` (conforming files a too-strict reader would wrongly reject)
and `hostile/` (files built to attack the reader) separates two goals that
pull in opposite directions. The first guards against over-strictness, the
second against under-strictness, and a single category blurs which failure a
test is protecting against.

```text
tests/xlsx/
├── valid/
│   ├── minimal.xlsx
│   ├── shared_strings.xlsx
│   ├── inline_strings.xlsx
│   ├── numeric_types.xlsx
│   ├── booleans.xlsx
│   ├── dates.xlsx
│   ├── formulas.xlsx
│   ├── empty_cells.xlsx
│   ├── sparse_rows.xlsx
│   ├── multiple_sheets.xlsx
│   ├── unicode.xlsx
│   ├── utf8_edge_cases.xlsx
│   └── large_shared_strings.xlsx
│
├── unusual-valid/
│   ├── strict_ooxml.xlsx
│   ├── no_shared_strings.xlsx
│   ├── reordered_zip_entries.xlsx
│   ├── unusual_relationship_paths.xlsx
│   ├── zip64.xlsx
│   └── very_large_sheet.xlsx
│
├── invalid/
│   ├── truncated_zip.xlsx
│   ├── corrupt_central_directory.xlsx
│   ├── missing_workbook.xml.xlsx
│   ├── missing_relationship.xlsx
│   ├── malformed_sheet_xml.xlsx
│   ├── malformed_shared_strings.xlsx
│   ├── bad_cell_reference.xlsx
│   └── invalid_xml_encoding.xlsx
│
└── hostile/
    ├── zip_bomb.xlsx
    ├── huge_shared_string.xlsx
    ├── extreme_row_number.xlsx
    ├── extreme_column_number.xlsx
    ├── duplicate_entries.xlsx
    └── recursive_relationships.xlsx
```

### 17.4b Status, 2026-09-19: built in-test, not committed

The adversarial half of the tree above is implemented, as
`tests/testthat/test-malformed.R`, `test-hostile.R` and `test-unusual.R`,
built byte by byte by `helper-zip.R` rather than committed as `.xlsx` files.

This is a deliberate split from the rule that fixtures are committed. That
rule exists so a *corpus* file has provenance -- it came from somewhere, and
its bytes must not drift. A synthetic adversarial input has the opposite
property: its value is entirely in how it is malformed, which a committed
binary hides. `write_zip()` and `write_workbook()` make the malformation the
literal subject of each test -- `central_offset_delta = 64L`, a
`declared_size` the member cannot back, the same part name twice -- and no ZIP
library will produce those on request, so the bytes have to be assembled by
hand regardless. Committed fixtures remain the rule for 17.1--17.3, which are
real files from real projects.

This needed no reading API. `xlsx_sheets()` already drives miniz, Expat and
xlsxio end to end, so every layer is reachable today.

What this established about the current reader:

| Behavior | Status |
| --- | --- |
| Internal entity expansion (billion laughs) | Not performed; reference survives verbatim |
| External entities (XXE) | Not resolved; no file is read off disk |
| Pathological nesting | Refused |
| Declared size larger than the member | Refused on header arithmetic, no allocation attempt |
| Duplicate archive members | First in the central directory wins, deterministically |
| Corrupt central directory / overcounted entries | `zuxlsx_zip_error` |
| Malformed or non-UTF-8 XML | Refused |
| **Corrupt CRC-32** | **Not detected** -- see below |

The first two hold because of how Expat behaves by default, not because
zuxlsx configures it. xlsxio calls `XML_ParserCreate` itself, so the defense
is inherited and could be lost silently in an xlsxio bump. That is why they
are pinned by assertion rather than assumed.

**Known gap: CRC-32 is never verified.** miniz's extract-iter path does not
check it, so a member whose bytes were corrupted in transit parses as if
intact. `test-hostile.R` characterizes this with a test that is written to
fail once validation is added. Section 16 lists corrupt archives among the
things to defend against; nothing does so yet.

Still to build: the `valid/` category, which needs the reading API before its
contents can be asserted on, and `strict_ooxml.xlsx` and `zip64.xlsx`, which
need a real producer rather than a hand-assembled archive.

---

## 18. Fuzz testing

The format is well suited to structure-aware fuzzing.

Instead of only mutating arbitrary bytes:

```text
valid XLSX
   |
   v
unpack ZIP
   |
   v
select component
   |
   +-- workbook.xml
   +-- relationships
   +-- sharedStrings.xml
   +-- styles.xml
   +-- worksheet XML
   +-- ZIP metadata
   |
   v
mutate
   |
   v
repack
   |
   v
zuxlsx
```

Useful mutations include:

- delete XML elements
- duplicate elements
- truncate XML
- corrupt shared-string indices
- alter relationship targets
- duplicate ZIP members
- reorder ZIP entries
- inflate declared dimensions
- create sparse extreme row numbers
- mutate cell type attributes

This could later integrate naturally with a `zufuzz` package.

---

## 19. Portability

The design should support:

- Linux
- macOS
- Windows / Rtools

Using static/native libraries supplied by `zuxml` and `zukomp` avoids the main portability problem of trying to link directly against another R package's loaded shared object.

The package should not rely on:

```text
zuxml.so
zukomp.so
```

being loadable by the platform dynamic linker at runtime.

Instead:

```text
zuxml / zukomp
      |
      v
build-time static linkage
      |
      v
zuxlsx shared library
```

This should also make binary R packages easier to relocate.

---

## 20. Licensing

The licenses of all vendored and linked components must remain compatible.

Expected stack:

```text
xlsxio  -> MIT
Expat   -> MIT-style
miniz   -> MIT / public-domain-compatible terms depending on version
```

`zuxlsx` should preserve required license notices for the xlsxio code it vendors.

`zuxml` and `zukomp` remain responsible for the notices associated with their vendored libraries, but redistribution through static linking should still be reviewed when preparing CRAN/package licensing metadata.

---

## 21. Initial implementation scope

Version 0.1 should focus on:

1. Open `.xlsx` ZIP archive using miniz.
2. Enumerate workbook sheets.
3. Parse workbook relationships.
4. Parse shared strings.
5. Stream worksheet XML through Expat.
6. Emit rows and cells.
7. Build an R `data.frame`.
8. Support basic scalar cell types.
9. Support dates/datetimes.
10. Provide clear structured errors.
11. Add a representative interoperability test corpus.

Out of scope initially:

- writing `.xlsx`
- charts
- images
- macros / `.xlsm` manipulation
- pivot tables
- rich formatting preservation
- formula calculation
- legacy `.xls`

Formula cells can expose the cached value and optionally the formula text, but `zuxlsx` should not evaluate formulas.

### Status, 2026-09-19: 7 of 11

Done: 1 open the archive, 2 enumerate sheets, 3 parse relationships, 4 parse
shared strings, 5 stream worksheet XML, 6 emit rows and cells, 8 basic scalar
cell types, 10 structured errors.

Partial: 9 dates -- a date is identified and its serial number returned, but
not converted, because the workbook epoch is not read yet (section 11).
11 the corpus -- the adversarial categories exist, `valid/` does not.

Not started: 7 build an R `data.frame`, which is `read_xlsx()` and the column
builders of section 14.

---

## 22. Design rationale

The core design is intentionally small:

```text
           zuxlsx
              |
            xlsxio
          /         \
       Expat        miniz
         ^            ^
         |            |
       zuxml        zukomp
```

Advantages:

- no additional system XML dependency
- no additional ZIP dependency
- no minizip requirement
- no duplicated vendoring of Expat/miniz in source
- simple streaming architecture
- compact native dependency graph
- reusable `zu*` package ecosystem
- static/native linking keeps runtime behavior simple
- natural path toward fuzzing and hardening

The main adaptation cost is replacing xlsxio's minizip/libzip ZIP backend with a thin miniz backend.

That is preferable to introducing another ZIP implementation solely to satisfy xlsxio's existing API.

---

## 23. Summary

`zuxlsx` should be a thin R-oriented XLSX reader built from three layers:

```text
xlsxio
  -> understands OOXML / XLSX

zuxml
  -> provides Expat headers and native implementation

zukomp
  -> provides miniz headers and native implementation
```

`zuxlsx` declares:

```text
LinkingTo:
    zuxml,
    zukomp
```

and links the native libraries supplied by those packages into `zuxlsx` at installation time.

The resulting package has a self-contained native reader based on:

```text
XLSX ZIP
  -> miniz
  -> Expat
  -> xlsxio
  -> R column builders
```

This keeps the implementation small while reusing the existing `zu*` native-library ecosystem.
