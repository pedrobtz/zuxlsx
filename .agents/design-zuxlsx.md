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

### Status, 2026-09-19: implemented, including both epoch traps

`xl/styles.xml` is parsed as of vendored patch 0003, and a cell's style index
resolves to "is this number a date or a time" through `cellXfs` and `numFmts`.
`xlsx_cells()` reports such a cell as type `date` and hands back the serial
number unchanged.

`read_xlsx()` converts, `xlsx_cells()` does not. The serial number is the
honest answer at cell level, because the epoch is a property of the workbook
rather than of the cell.

`workbookPr/@date1904` is read as of vendored patch 0004 and reaches R as an
attribute on the `xlsx_cells()` result. It matters more than its rarity
suggests: the readxl fixture `blanks.xlsx` carries `date1904="1"`, having been
authored on a Mac, so the existing corpus already contains the case. Read as a
1900 workbook, every date in it is four years and a day out.

The 1900 system has a second trap. Excel reproduces a Lotus 1-2-3 bug and
treats 1900 as a leap year, so serial 60 is a 29 February 1900 that never
existed. No single origin can therefore be right: from serial 61 the phantom
day has been counted and the origin is 1899-12-30, while below it the origin
is really 1899-12-31, which is what makes serial 1 come out as 1 January 1900
the way Excel shows it. Using 1899-12-30 throughout, as is common, puts every
date before March 1900 one day early. Serial 60 itself becomes `NA` rather
than being bent onto a neighbouring day.

A column whose serials are whole numbers becomes `Date`; one where any cell
carries a time of day becomes `POSIXct` in UTC, since coercing to `Date` would
drop the time silently.

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

### Status, 2026-09-19: `xlsx_sheets()`, `xlsx_cells()` and `read_xlsx()`

`read_xlsx(path, sheet, col_names, range)`, `xlsx_cells()`, `xlsx_rows()` and
`xlsx_read_cells()` are all implemented. Section 12 is complete.

`xlsx_read_cells(path, sheet, callback, chunk_size)` hands the callback a
chunk of cells at a time and stops when it returns `FALSE`. A chunk never
splits a row, so `chunk_size` is a lower bound: the boundary falls at the
first row end at or after it. A callback that saw half a row could do nothing
useful with it.

It is the only entry that calls R while the archive and the parser are open,
which is why both are owned by external pointers with registered finalizers
rather than by the C stack. The callback may signal a condition or be
interrupted, and either unwinds past every `close()` on that stack. Asserted
rather than assumed: an erroring callback propagates its message, the same
file then reads normally, and 300 aborted reads return to the same in-use
memory after a `gc()`.

**Measured, and the benefit is not the one section 9 implies.** On a 20000 by
10 sheet:

| | elapsed |
| --- | --- |
| `xlsx_cells()`, whole sheet | 0.42 s |
| `xlsx_read_cells()`, read to the end | 0.37 s |
| `xlsx_read_cells()`, stopping after one chunk | **0.02 s** |

Early termination is the win, and it is a large one: finding something near
the top of a large worksheet costs a twentieth of reading it.

Peak memory for a *full* read is not improved -- 68 MB against 62 MB for
`xlsx_cells()` on the same sheet. Each chunk is an allocation R need not
collect before the next is made, so the high-water mark is unchanged even
though nothing holds the whole worksheet at once. What the API bounds is what
the *caller* has to keep, which is the useful guarantee and the one the
documentation makes.

`range` takes A1 notation, and either corner may name a cell, a column or a
row: `"B2:D10"` is a rectangle, `"A:C"` is three whole columns, `"2:10"` nine
whole rows. Corners may be given in either order. The rectangle is what is
asked for rather than what the data happens to fill, so a range wider than the
sheet still yields its own columns; narrowing it to the data would make the
result depend on the file rather than the request.

**Blank rows are kept, including directly beneath the header.** A worksheet
may omit an empty row from its XML, and until `range` existed `read_xlsx()`
dropped such a row when it fell immediately after the header while preserving
it anywhere else -- an inconsistency that came from deriving the row span from
the body rather than from the sheet, and that the readxl fixture
`blanks.xlsx` records in its `same_row_first` and `same_row_middle`
worksheets. Keeping every blank row is easier to predict than keeping only the
interior ones, and `range` is now the way to start further down.

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

### Status, 2026-09-19: implemented, but as a post-pass rather than streaming

`read_xlsx()` builds columns in R from the cells `xlsx_cells()` returns, in
`R/read.R`. Promotion is by inspection rather than progressively: a column of
blanks is logical, booleans stay logical, numbers give a double, dates give
`Date` or `POSIXct`, and anything mixed or holding a string or a cell error
becomes character. Rows are placed by row number, not by order of arrival, so
a column that is blank in the middle keeps its alignment.

**This is not yet the streaming pipeline section 9 describes.** Cells are
materialised in full before columns are built, so peak memory is roughly the
size of the sheet's data rather than of one column at a time. The XML is still
streamed -- the parser suspends per cell and the worksheet is never held as
text -- so `DESCRIPTION`'s claim that a workbook need not be held in memory in
full remains true of the document, but the cell list is a second copy that a
streaming builder would not need.

### Done, 2026-09-20: columns are built in C, and the text mostly stays there

Measured first, on a 20000 by 10 sheet of 200000 cells. The intermediate cell
list was 12.8 MB against a 4.7 MB result, and 7.5 MB of that -- 59% -- was the
cell text. Seven of the ten columns were numeric and discarded it.

**A streaming builder cannot discard that text.** Promoting a column to
character returns each cell as it was written, and a column is only known to
be character once a string appears in it, which may be thousands of rows after
the numbers:

```text
stored text     '1.50'  '2.0e3'  '0.30'
read_xlsx gives '1.50'  '2.0e3'  '0.30'
from a double   '1.5'   '2000'   '0.3'
```

So the section as originally written asked for something whose price was not
understood: dropping the text would silently rewrite every mixed column.

What was done instead is to decide each column's type in C, from the cell list
that already exists there, and build only what the column turns out to be. A
numeric column emits doubles and its text is never allocated in R at all,
while a column that promotes still gets the original text, because in C it is
still there when the decision is made. `C_read_xlsx()` does that; the type
rules mirror R's former `build_column()` exactly.

Measured after:

| | peak | above baseline | elapsed |
| --- | --- | --- | --- |
| before, pivoting in R over `xlsx_cells()` | 119 MB | 76 MB | 0.48 s |
| after, columns built in C | 56 MB | 18 MB | 0.30 s |

Four times less memory, and a third faster, which was not the aim. The earlier
estimate in this section of 29 MB down to 17 MB was wrong in the conservative
direction: it had not counted the type factor and the intermediate data frame
that `read_xlsx()` was also building.

The epoch arithmetic deliberately stayed in R. It is the fiddliest part of the
package -- two epochs, one counting a day that never existed -- it is already
covered by tests, and being vectorised it costs one call per date column
rather than one per cell. C reports which columns are date serials and R
converts them.

Range clipping moved into C as well, so a range no longer pays for the rest of
the worksheet in memory before discarding it.

Evidence the rewrite is faithful: all 346 tests passed unchanged on the first
run, and the external corpus reports the identical 1785804 cells across 363
real workbooks.

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

`zuxlsx_input_error`, `zuxlsx_memory_error` and
`zuxlsx_unsupported_format_error` are additions to the list above.
`zuxlsx_sheet_error` arrived with `xlsx_cells()`, and `zuxlsx_xml_error` is
raised as of 2026-09-19, naming the offending part and line.

Only `zuxlsx_type_error` is still unraised, and it may never be: nothing
promotes a cell to a column type that could conflict, because a column that
cannot hold its cells becomes character rather than failing.

`zuxlsx_xml_error` needed no sixth xlsxio patch. xlsxio does not report why a
parse produced nothing, but Expat and miniz are both linked here directly, so
once a workbook has already failed to declare a worksheet the two parts that
must be well formed -- `[Content_Types].xml` and `xl/workbook.xml` -- are
parsed again in this package's own code purely to find out which one is
broken. That path runs only on a failure, so it costs nothing, and it turns
"declares no worksheets" into "xl/workbook.xml could not be parsed (line 4)".

The boundary is the point: XML that parses but declares no worksheet stays
`zuxlsx_ooxml_error`. Calling that an XML error would send the reader looking
for a syntax problem that is not there.

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

### Settled, 2026-09-19: three tiers, not one suite

Examples are a fourth thing, and were doing nothing at all. Every exported
function documented `system.file("extdata", "two-sheets.xlsx")` guarded by
`if (nzchar(path))`, and that file did not exist, so `system.file()` returned
`""` and every example body was skipped -- on CRAN, on every platform, since
the package was created. The guard made it silent.

`inst/extdata/two-sheets.xlsx` now exists, generated by
`tools/fixtures/make-extdata.R` and committed, and the guards are gone. This
is worth more than tidiness: CRAN runs examples on every platform it checks,
so the documented usage of the public API is now verified there rather than
merely printed. `tests/testthat/test-extdata.R` asserts what the fixture
contains, because an example that stops demonstrating what its text claims is
worse than no example; the generator's `--check` mode asserts the committed
bytes are still what it produces, and runs in CI because `tools/` is not
installed and a test cannot reach it.

The question was posed as ship-with-the-package versus CI-only, and both
answers were wrong. Tests do not all have to live in the same place, and the
expensive ones do not belong in the package at all.

**Tier 1, `tests/testthat/` — ships.** Fast, small, deterministic. Its job is
regression protection on every platform CRAN checks, so its binding
constraints are tarball size and check time, not coverage. It stays cheap
deliberately.

**Tier 2, `tools/corpus/` — committed, not shipped.** The external corpus and
its runner, excluded by `.Rbuildignore`, run in CI on every pull request.
Because it does not ship, the size limit that forced talk of "a few dozen
curated files" disappears: the whole of POI's spreadsheet corpus is in scope,
and curation becomes a question of coverage rather than bytes.

**Tier 3 — run once, record the result.** Soundness work that does not need
repeating on every change: fuzzing (section 18), sanitiser runs, a full
differential against another reader. The script stays so it can be re-run when
something underneath it changes; the finding goes in this document.

The corpus files are fetched rather than committed. 20 MB of another project's
fixtures does not belong in this repository's history, and `checksums.sha256`
pins every byte, so a moved or rewritten upstream fails the fetch instead of
silently changing what is tested. The network dependency is acceptable
precisely because it is tier 2: tier 1 never touches the network, so the suite
that must not flake cannot.

Licensing stays simple under this split. Nothing from POI is redistributed,
so the Apache-2.0 notice obligations that a vendored subset would have created
do not arise.

### 17.1 xlsxio fixtures

Use xlsxio's own fixtures and tests first because they directly exercise the upstream reader logic being adapted.

### 17.2 SheetJS test files -- unavailable

The obvious first choice, and it cannot be used. GitHub has disabled
`SheetJS/test_files` under its Terms of Service, flagged `private_information`;
the API returns 403 and the tarball 404s. Even if a mirror were found,
vendoring files that were removed for containing personal data into a package
is not a reasonable thing to do. Recorded so the question is not reopened
blindly.

The categories it would have covered -- shared and inline strings, formulas,
sparse sheets, unusual styles, Unicode, dates, malformed files -- are covered
by POI below and by the generated corpus of 17.4.

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

### 17.3a Status, 2026-09-19: wired up, and it found two things

`tools/corpus/` fetches all 352 `.xlsx` files from POI's
`test-data/spreadsheet` at a pinned commit and reads every worksheet of every
one. 334 read; 18 error, and `expected.tsv` pins each outcome so that a file
which starts failing, or starts passing, is reported either way.

Most of the 18 are correct refusals: twelve clusterfuzz-minimised or crash
testcases, and a `.docx` renamed `.xlsx`. Two more were checked rather than
assumed -- `deep-data.xlsx` has no end-of-central-directory at all, which
`unzip` also refuses, so `zuxlsx_zip_error` is right.

Two findings came out of it.

**`49609.xlsx` was a real interoperability gap, now fixed** by vendored patch
0005. It is a valid archive holding valid OOXML, but its member names use
backslashes and lowercase -- `[content_types].xml`, `xl\styles.xml`,
`_rels\.rels`. xlsxio opened the literal `[Content_Types].xml` and located
members with `MZ_ZIP_FLAG_CASE_SENSITIVE`, so the part was never found. Excel
reads that file; now so does this. The corpus count went from 334 to 335, and
`run` reported the improvement in the same way it would report a regression,
which is what the baseline is for.

The fix is not simply "clear the case-sensitive flag", and the reason is worth
keeping. `mz_zip_reader_locate_file_v2()` resolves a duplicated member name
differently depending on that flag -- set, the earlier member wins; clear, the
later one. Clearing it turned this package's duplicate handling from
first-wins to last-wins, which `test-hostile.R` caught immediately. Which copy
of a duplicated part a reader picks is a security property, so it must follow
from position rather than from a lookup flag, and patch 0005 scans the central
directory itself and takes the first match.

Matching tolerantly also widens what counts as a duplicate: two members
differing only in case, or only in which slash they use, now collide where
they did not before. Those resolve by position as well, and are tested.

**Encrypted workbooks needed their own error, and so did xlsb.** Both are now
`zuxlsx_unsupported_format_error`; see section 21a.

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

### 17.4c Status, 2026-09-19: `valid/` covered, and it found a bug

`test-valid.R` covers the `valid/` category -- numeric forms parsed to the
double R would parse, formula cells reporting their cached value, sparse rows
and columns, a 2000-entry shared string table resolved at both ends, a 33000
character string, astral-plane and right-to-left text, XML-escaped characters,
and worksheets read independently of one another.

Separately, `test-corpus.R` asserts the *content* of the seven committed
workbooks for the first time. Until `read_xlsx()` existed they could only be
checked for opening, which left the real-producer corpus -- the part that
actually tests interoperability -- almost unexercised.

**Doing so found a row-alignment bug.** A row omitted from the worksheet XML
was being dropped rather than kept as a blank row, so values on either side of
a gap moved next to each other and every row index below it was wrong. The
readxl fixture `blanks.xlsx` contains a worksheet named `same_row_middle`
which exists to catch exactly this, and it had been passing only because
nothing asserted its contents.

The cause was trusting xlsxio's row padding, which inserts a single row for an
omitted range however wide it is: a sheet with data on rows 1, 2 and 5 arrives
as rows 1, 2, 4, 5. `read_xlsx()` now spans the range of row numbers the cells
themselves carry, which is independent of that padding. The quirk is pinned by
a characterisation test rather than patched in xlsxio, since nothing above the
cell layer needs the padding to be right.

### 17.4d Strict OOXML, 2026-09-20: found by looking, not by erroring

`strict_ooxml.xlsx` was listed here as still to build, and needing a real
producer. Both were wrong. Apache POI's corpus already carried four strict
workbooks, and they were already being read -- as completely empty.

ECMA-376 has two namespace families. Transitional is what Excel writes by
default; strict is the ISO/IEC 29500 variant it writes for "Strict Open XML
Spreadsheet", and the relationship `Type` attributes are among the URIs that
differ. xlsxio matched the transitional spelling alone, so no worksheet,
shared string table or styles part was ever located. Vendored patch 0006 fixes
it; the four files went from 0 cells to 6, 15, 31 and 37.

**The corpus recorded all four as `ok` the whole time**, because its criterion
was "did reading raise a condition". A workbook that lists its worksheets and
then yields nothing passes that test perfectly, which is precisely the failure
a corpus exists to catch.

So `expected.tsv` now records the sheet and cell counts as well as the
outcome, and `run` compares all of them. Silent emptiness is visible, and so
is a fix: under the old format the patch above changed nothing that the
baseline could see.

That immediately surfaced 25 further workbooks that list sheets and read no
cells. Spot-checked rather than assumed: they contain no `<c>` elements at all,
being POI fixtures for headers, tab colours and drawings. Genuinely empty, not
more of the same.

### 17.4e ZIP64, 2026-09-20

Built by hand, as suspected, and no producer was needed. ZIP64 lifts the
format's 32-bit limits: a field that will not fit is stored as all-ones and
the real value moves into a ZIP64 extra field, with a ZIP64 end of central
directory record and locator ahead of the ordinary one. `write_zip64()`
produces tiny archives that use those structures anyway, which is how the
format is covered without a four gigabyte fixture -- and is what writers
themselves do when streaming, not knowing the final size in advance.

All three places the escaping can happen are covered: the end-of-central-
directory counts and offsets, the per-entry sizes and local header offset, and
both together. A reader handling only one of them fails on real archives. The
fixtures were cross-checked against system `unzip`, which accepts them, so
they are well-formed ZIP64 rather than merely readable by miniz.

The negative controls matter more than the positive ones here, because a
reader that ignored ZIP64 entirely would pass the positive tests. Destroying
the ZIP64 end-of-central-directory signature, or the central directory offset
inside it, both give `zuxlsx_zip_error` -- so those structures are genuinely
being read.

**Characterised, not required: the ZIP64 locator is not consulted.** miniz
finds the record by scanning for its signature rather than by following the
locator, so a locator pointing far past the end of the file changes nothing.
That is permissive rather than wrong, since the record it finds is the right
one, but it means an archive malformed in exactly that way is read rather than
refused. Pinned by a test, because a future miniz that began honouring the
locator would change it silently.

With this, section 17.4's tree is complete.

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

### 21a. Formats that are not broken files

Two kinds of real spreadsheet reached this reader and were reported as
damage. Both now raise `zuxlsx_unsupported_format_error`, which exists to
separate "zuxlsx cannot read this" from "this file is corrupt".

**Encrypted workbooks.** Password-to-open does not protect a ZIP; it wraps the
package in an OLE2/CFB container, so nothing that opens ZIPs can even see the
workbook. Detected from the eight byte compound-file signature before the file
is handed to the reader, since afterwards the only available answer is
"corrupt archive".

That signature identifies the container, not what is inside it: a legacy .xls
is also OLE2. The original costing said distinguishing the two meant reading
the CFB directory, which is "most of the work of reading a CFB", so the
message named both possibilities rather than guessing.

**Revised 2026-09-20.** That over-costed it. Reading a *stream* out of a CFB
does need the FAT, the miniFAT, the directory tree and the mini stream.
Reading the directory *names* needs the header, the FAT and the directory
chain, and stops there -- no mini stream, no stream contents, no password. It
is roughly 150 lines, and it is enough to tell the two apart: an encrypted
package has `EncryptionInfo` and `EncryptedPackage`, a BIFF workbook has
`Workbook` or `Book`.

So `ole2_kind()` now classifies, and the two formats get different advice.
`zuxlsx_encrypted_error` is a subclass of `zuxlsx_unsupported_format_error`,
so code written against the old behaviour keeps working while code that wants
to prompt for a password can catch the specific class. A container that is
neither still reports as plain OLE2 -- the classifier must not reach for a
better message when it does not have one.

Everything in it is bounds-checked and every walk is bounded, because a
workbook that arrives encrypted is a workbook somebody else produced. The
sector offset is computed in 64-bit so a sector number near 2^32 cannot wrap
into a small valid-looking offset; the directory walk is capped; a FAT chain
pointing at itself terminates; a name length outside 2..64 bytes is refused
before it is used. `test-ole2.R` sweeps truncations at every length through
the header and first sectors, seeded byte corruption, and a deliberately
self-referential FAT.

This does not read an encrypted workbook. It tells the user they have one.

**xlsb.** An `.xlsb` is a genuine OPC package -- a ZIP, with XML content types
and relationships. Only the workbook and worksheet parts differ, holding BIFF12
binary records instead of XML, so xlsxio finds no part of the content type it
wants and the workbook appears to declare no worksheets. Recognised by the
presence of `xl/workbook.bin`, checked only once a workbook has already failed
to declare a worksheet, so a file that reads normally pays nothing.

### 21b. Decryption: deferred, 2026-09-19

Reading an encrypted workbook was costed and deliberately left for later.

It needs four things, and only the last is small: a CFB container reader
(sector chains, FAT and miniFAT, directory tree -- 600 to 900 lines, of which
the directory-name subset is now written, see 21 above);
AES-128 and AES-256 in ECB and CBC, plus SHA-1 and SHA-512, none of which this
package links today; both schemes, since standard encryption (Office 2007,
AES-128 ECB, SHA-1) and agile encryption (Office 2010 onward and the default
since 2013, usually AES-256 CBC with SHA-512) share nothing but a container;
and the glue that hands the decrypted bytes to miniz. Roughly 2000 to 2500
lines.

The obstacle is section 3 rather than the size. Depending on the `openssl` R
package would require system libssl and contradict the no-system-dependency
premise outright, so the consistent route is a fourth sibling -- `zucrypt`,
vendoring a small AES and SHA the way `zuxml` vendors Expat -- which roughly
doubles the surface of the project.

Three consequences worth recording. Decryption cannot stream: the whole
package must be decrypted before the ZIP is readable, so section 9's promise
would need qualifying for encrypted files. A password passed from R cannot be
wiped, since R strings are immutable and may be copied or cached, which is
documentable rather than fixable. And correctness needs known-answer vectors
for AES and SHA, because "it decrypted something" proves nothing.

Of the three main R readers -- readxl, openxlsx and openxlsx2 -- none supports
this, and all three fail less informatively than detection alone achieves. If
it is built, agile should come first, since that is what current Excel writes.
### Status, 2026-09-19: 10 of 11

Done: 1 open the archive, 2 enumerate sheets, 3 parse relationships, 4 parse
shared strings, 5 stream worksheet XML, 6 emit rows and cells, 7 build an R
`data.frame`, 8 basic scalar cell types, 9 dates and datetimes including both
epochs, 10 structured errors.

Partial: 11 the corpus -- `valid/`, `unusual-valid/`, `invalid/` and
`hostile/` are all covered, and the committed workbooks are asserted on
content rather than only on opening. Outstanding are `strict_ooxml.xlsx` and
`zip64.xlsx`, which need a real producer, and the external corpora of 17.1 to
17.3, which remain an open decision.

Known limitations rather than missing items: column building is a post-pass
rather than streaming (section 14), `xlsx_read_cells()` is unimplemented
(section 12), and `zuxlsx_xml_error` and `zuxlsx_type_error` remain unraised
(section 15).

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
