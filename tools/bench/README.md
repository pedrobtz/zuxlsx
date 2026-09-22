# Benchmarks

Times `zuxlsx` against [readxl](https://readxl.tidyverse.org) and
[openxlsx2](https://janmarvin.github.io/openxlsx2/) on a workbook large
enough that the streaming pipeline of design §9 has something to prove.

Maintainer scripts: nothing here runs during `R CMD check`, and no part of the
package depends on their output.

## Getting a workbook

```sh
tools/bench/fetch-workbooks              # every id in workbooks.tsv
tools/bench/fetch-workbooks xlsx100mb    # just one
```

Downloads go to `$ZUXLSX_BENCH_DIR`, or `${XDG_CACHE_HOME:-~/.cache}/zuxlsx-bench`
— **outside the repository, deliberately**. These files are 100 MB and up and
their provenance and licence are not established, so they are not fixtures.
Committed fixtures live in `tests/testthat/sheets/` with a `MANIFEST.tsv`.

`workbooks.tsv` pins each one by sha256; a mismatch fails rather than being
silently benchmarked. A row with no sha256 yet gets one from
`fetch-workbooks --record`.

`xlsx100mb` is the interesting one, and not only for its size:

| | |
|---|---|
| download | 105,709,047 bytes |
| inflated | ~550 MB |
| `xl/sharedStrings.xml` | 160 MB — 8,844,372 references over 1,246,650 unique strings |
| sheets | 4, at 27,001 / 4,001 / 99,929 / 986,029 rows |
| also | `tables/`, `queryTables/`, `connections.xml`, a `customXml/` part |

Two edge cases come free with it: no sheet declares a `<dimension>`, so the
column count has to be inferred from the cells; and sheet 4 ends in styled but
empty rows out to `r="1043928"`, the classic way a reader ends up returning a
million blank rows.

## Running

```sh
Rscript tools/bench/bench-read.R                       # xlsx100mb, sheet 1
Rscript tools/bench/bench-read.R xlsx100mb 4           # the 986k-row sheet
Rscript tools/bench/bench-read.R some/other.xlsx       # a path works too
Rscript tools/bench/bench-read.R xlsx100mb "Tablo3"    # a sheet name works too
```

Two positional arguments: the workbook (an id from `workbooks.tsv` or a path)
and the sheet (an index or a name). It uses [bench](https://bench.r-lib.org),
one iteration per expression, and reports median time and `mem_alloc`.

The two tables separate the two halves of the cost:

- **list worksheets** opens the archive and parses `xl/workbook.xml` only. For
  readxl and zuxlsx that is a few hundred kilobytes of a 105 MB file; openxlsx2
  has no such path, since `wb_load()` inflates and parses the whole package, so
  its number there is a full read. That is the finding, not an unfair
  comparison.
- **read one sheet** materialises one sheet as a data frame: shared strings,
  cells and column building.

Both tables are one iteration per expression, so they are whole-read timings,
not a microbenchmark. The three readers are not checked against each other:
that is what `tools/corpus/sweep.R` is for.

## How it measures

`bench::mark(iterations = 1)`: one call per expression, so the figures are
whole-read timings rather than a microbenchmark, and everything after the first
expression is warm — the OS page cache holds the file. Cold-cache numbers need
`purge` (macOS) or `echo 3 > /proc/sys/vm/drop_caches` (Linux) between runs.

`mem_alloc` is R-level allocation only. The C heap where xlsxio, RapidXML and
openxlsx2 do their work does not appear in it, and all three packages run in
one process, so for memory rather than time watch RSS from outside, one
workbook at a time.
