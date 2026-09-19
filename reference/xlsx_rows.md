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
xlsx_rows(path, sheet = 1)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- sheet:

  The worksheet to read: either its name, or its position in the
  workbook.

## Value

A list with one character vector per row, from the first row of the
worksheet to the last. Every vector is as long as the widest row, so the
nth element of each is the nth column. Blank cells are `NA`.

## See also

[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
for typed cells,
[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
for a data frame.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
if (nzchar(path)) xlsx_rows(path)
```
