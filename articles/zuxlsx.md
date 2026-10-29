# Getting started with zuxlsx

``` r

library(zuxlsx)
```

zuxlsx reads `.xlsx` workbooks into R. It needs no system XML, ZIP or
cryptography library: the parts it builds on are compiled into the
package, so installing it is all there is to do. It reads; it does not
write – see the end of this article for what to use instead.

The examples use a small workbook that comes with the package.

``` r

path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
```

## What is in the workbook

[`xlsx_sheets()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_sheets.md)
lists the worksheets, in the order the workbook keeps them. It reads
only the workbook’s index, not the sheets, so it costs the same on a
small file as on a large one.

``` r

xlsx_sheets(path)
#> [1] "readings" "notes"
```

## Reading a worksheet

[`xlsx_read()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_read.md)
reads a worksheet into a data frame. By default it reads the first
worksheet and takes the column names from its first row.

``` r

readings <- xlsx_read(path)
readings
#>   station reading checked      taken
#> 1   north   12.50    TRUE 2024-02-02
#> 2   south    9.75   FALSE 2024-02-03
#> 3    east   14.25    TRUE 2024-02-04
```

Each column takes the type its cells support. Nothing had to be
declared: the numbers are doubles, the `TRUE`/`FALSE` cells are logical,
and the dates – which an `.xlsx` stores as numbers with a date format –
are `Date`s.

``` r

vapply(readings, function(x) class(x)[1], character(1))
#>     station     reading     checked       taken 
#> "character"   "numeric"   "logical"      "Date"
```

A column that mixes kinds of value, or holds a string or a cell error
such as `#DIV/0!`, becomes character, with each cell as it was written.
A date that carries a time of day becomes `POSIXct` rather than losing
the time.

## Choosing a worksheet, and part of one

`sheet` takes a name or a position.

``` r

xlsx_read(path, sheet = "notes")
#>                    note
#> 1 calibrated in January
#> 2                 µg/m³
identical(xlsx_read(path, sheet = 2), xlsx_read(path, sheet = "notes"))
#> [1] TRUE
```

`range` takes a rectangle in A1 notation. Either corner may name a cell,
a column or a row, so `"B1:C3"`, `"A:B"` and `"2:4"` all work.

``` r

xlsx_read(path, range = "B1:C3")
#>   reading checked
#> 1   12.50    TRUE
#> 2    9.75   FALSE
```

When the first row of what is read is data rather than names, say so
with `col_names = FALSE`, and the columns are named by position.

``` r

xlsx_read(path, range = "A2:B4", col_names = FALSE)
#>      X1    X2
#> 1 north 12.50
#> 2 south  9.75
#> 3  east 14.25
```

Without `range`, the table is the rectangle the worksheet’s non-empty
cells span, so one that starts further down the sheet, at `B3` say,
reads with its header from row 3.

## When something is wrong

Every error zuxlsx raises carries a condition class, and the class – not
the wording of the message – is what to rely on. A file that is not
there is an input error; one that is not a ZIP archive at all is a ZIP
error; a damaged part is an XML or ZIP error naming the part.

``` r

not_a_workbook <- tempfile(fileext = ".xlsx")
writeLines("this is not a spreadsheet", not_a_workbook)

tryCatch(
  xlsx_read(not_a_workbook),
  zuxlsx_zip_error = function(e) "not a readable xlsx file",
  zuxlsx_error = function(e) "some other problem"
)
#> [1] "not a readable xlsx file"
```

Every class is a subclass of `zuxlsx_error`, so one handler can catch
them all.
[`?"zuxlsx-conditions"`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md)
lists them. One is worth knowing early: a password-protected workbook
read without a password is `zuxlsx_encrypted_error`, and every reader
takes `password =` to open one.

## When a data frame is the wrong shape

A worksheet is not always a table: a report with stacked blocks, a
header several rows deep, notes in the margins. For those,
[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
returns one row per cell, with its position, its own type and its text,
and
[`xlsx_rows()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_rows.md)
returns the sheet row by row as text.
[`xlsx_stream_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_stream_cells.md)
reads a sheet a chunk at a time, for one too large to hold, or to stop
as soon as something is found.

``` r

head(xlsx_cells(path))
#>   row col   type   value number
#> 1   1   1 string station     NA
#> 2   1   2 string reading     NA
#> 3   1   3 string checked     NA
#> 4   1   4 string   taken     NA
#> 5   2   1 string   north     NA
#> 6   2   2 number    12.5   12.5
```

## Writing workbooks

zuxlsx does not write `.xlsx` files, and is not going to. For that, use
[writexl](https://docs.ropensci.org/writexl/) for a plain data frame or
[openxlsx2](https://janmarvin.github.io/openxlsx2/) when formatting
matters.
