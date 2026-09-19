# Read a worksheet into a data frame

Reads a worksheet and assembles its cells into columns, giving each
column the type its cells support. This is the high-level reader;
[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
is the cell-by-cell view underneath it.

## Usage

``` r
read_xlsx(path, sheet = 1, col_names = TRUE)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- sheet:

  The worksheet to read: either its name, or its position in the
  workbook.

- col_names:

  Whether the first row holds column names. When `FALSE`, columns are
  named `X1`, `X2` and so on.

## Value

A data frame.

## Details

Column types are inferred by promotion. A column of blanks is logical,
one of booleans stays logical, numbers give a double, and anything that
mixes types, or that holds a string or a cell error, becomes character.
A column whose cells are all dates becomes a `Date`, or a `POSIXct` when
any of them carries a time of day.

## See also

[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
for the cells themselves, and
[`xlsx_sheets()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_sheets.md)
to list the worksheets.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
if (nzchar(path)) read_xlsx(path)
```
