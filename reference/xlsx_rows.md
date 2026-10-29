# Read a worksheet as rows

Returns a worksheet row by row, as the text of each cell, without
inferring a type for any column. This is the row-oriented counterpart to
[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md),
and is the shape to reach for when a worksheet is not rectangular enough
for
[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
– a report with stacked blocks, or a file whose header is several rows
deep.

## Usage

``` r
xlsx_rows(path, sheet = 1, password = NULL)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- sheet:

  The worksheet to read: either its name, or its position in the
  workbook.

  Cells the worksheet leaves out between the ones it writes come back as
  `"blank"`, and so may a few the file never names: the reader pads to
  keep positions aligned.
  [`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
  ignores blank cells when it decides where a table starts and ends.

- password:

  The password of a password-protected workbook, or `NULL` (the default)
  for one without. The workbook is decrypted in memory and never written
  to disk. Agile encryption – what Excel has written since 2013 – is
  supported; the older standard encryption is not, and is reported as
  such. Ignored for a workbook that is not encrypted. R cannot erase a
  string, so the password may stay in memory after the call.

## Value

A list with one character vector per row, from row 1 of the worksheet to
the last row holding a cell, so the nth element is row n. Every vector
is as long as the widest row, so the nth element of each is column n.
Blank cells, and rows with none, are `NA`.

## See also

[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
for typed cells,
[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
for a data frame.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
rows <- xlsx_rows(path)

# One character vector per row, every one as wide as the widest, with no
# type inference: a number is its text.
rows[[1]]
#> [1] "station" "reading" "checked" "taken"  
rows[[2]]
#> [1] "north" "12.5"  "1"     "45324"
```
