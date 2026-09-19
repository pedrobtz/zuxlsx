# Read a worksheet into a data frame

Reads a worksheet and assembles its cells into columns, giving each
column the type its cells support. This is the high-level reader;
[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
is the cell-by-cell view underneath it.

## Usage

``` r
read_xlsx(path, sheet = 1, col_names = TRUE, range = NULL)
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

- range:

  An A1-style cell range limiting what is read, or `NULL` for the whole
  worksheet. Either corner may name a cell, a column or a row, so
  `"B2:D10"` takes a rectangle, `"A:C"` takes three columns in full, and
  `"2:10"` takes nine rows in full. The corners may be given in either
  order. A range is read as its own rectangle: cells outside it are
  ignored, the top-left becomes the first row and column, and columns
  the range covers appear even where the worksheet left them empty. When
  `col_names` is `TRUE` the first row of the range supplies the names.

## Value

A data frame.

## Details

A worksheet may leave a row out of its XML rather than write an empty
one. Such a row is kept, as a row of `NA`, wherever it falls – including
directly beneath the header. Keeping every blank row is easier to
predict than keeping only the interior ones, and `range` is the way to
begin further down the sheet.

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

# Each column takes the type its cells support.
readings <- read_xlsx(path)
readings
#>   station reading checked      taken
#> 1   north   12.50    TRUE 2024-02-02
#> 2   south    9.75   FALSE 2024-02-03
#> 3    east   14.25    TRUE 2024-02-04
vapply(readings, function(x) class(x)[1], character(1))
#>     station     reading     checked       taken 
#> "character"   "numeric"   "logical"      "Date" 

# A worksheet by name, and part of one by range.
read_xlsx(path, "notes")
#>                    note
#> 1 calibrated in January
#> 2                 µg/m³
read_xlsx(path, range = "B1:C3")
#>   reading checked
#> 1   12.50    TRUE
#> 2    9.75   FALSE

# Without a header row, columns are named by position.
read_xlsx(path, range = "A2:B4", col_names = FALSE)
#>      X1    X2
#> 1 north 12.50
#> 2 south  9.75
#> 3  east 14.25
```
