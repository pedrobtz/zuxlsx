# Read a worksheet in chunks

Reads a worksheet a piece at a time, passing each piece to a function
rather than returning the whole thing. This is the low-level streaming
reader: use it when a worksheet is too large to hold, or when the answer
can be found without reading all of it.

## Usage

``` r
xlsx_read_cells(path, sheet = 1, callback, chunk_size = 10000L)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- sheet:

  The worksheet to read: either its name, or its position in the
  workbook.

- callback:

  A function of one argument, called with each chunk of cells. Return
  `FALSE` to stop reading.

- chunk_size:

  The least number of cells to gather before calling `callback`.

## Value

`TRUE` if `callback` stopped the read, `FALSE` if the worksheet was read
to the end. Returned invisibly.

## Details

`callback` is called with a data frame of cells in the shape
[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
returns. Returning `FALSE` from it stops the read, leaving the rest of
the worksheet unparsed; any other value continues.

A chunk never splits a row, so a callback can rely on seeing every cell
of a row together. `chunk_size` is therefore a lower bound rather than
an exact count: a chunk ends at the first row boundary at or after it.

## See also

[`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md),
which reads a whole worksheet at once, and
[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md),
which builds columns from it.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")

# Count the cells of each type without holding the worksheet.
totals <- integer(0)
xlsx_read_cells(path, 1, function(cells) {
  totals <<- c(totals, table(cells$type))
})

# Stop as soon as something is found. The rest of the sheet is not parsed.
first <- NULL
xlsx_read_cells(path, 1, function(cells) {
  hit <- cells[cells$type == "date", ]
  if (nrow(hit) > 0) {
    first <<- hit[1, ]
    FALSE
  }
})
first
#>   row col type value number
#> 8   2   4 date 45324  45324
```
