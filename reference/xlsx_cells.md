# Read the cells of a worksheet

Reads a worksheet one cell at a time and returns them in a data frame,
one row per cell. This is the low-level reader: it reports what is in
each cell without assembling columns or guessing a type for them, which
is what
[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
will do on top of it.

## Usage

``` r
xlsx_cells(path, sheet = 1)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- sheet:

  The worksheet to read: either its name, or its position in the
  workbook.

## Value

A data frame with one row per cell and the columns:

- `row`, `col`:

  Position, counting from 1.

- `type`:

  One of `"blank"`, `"number"`, `"string"`, `"boolean"`, `"error"` or
  `"date"`.

- `value`:

  The cell as written, as a string.

- `number`:

  The numeric value for `"number"`, `"boolean"` and `"date"` cells, and
  `NA` otherwise. A date is its Excel serial number; it is not converted
  here, because the epoch is a property of the workbook rather than of
  the cell.

## See also

[`xlsx_sheets()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_sheets.md)
to list the worksheets, and
[zuxlsx-conditions](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md)
for the errors this can raise.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
if (nzchar(path)) xlsx_cells(path)
```
