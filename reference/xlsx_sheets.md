# List the worksheets in an xlsx workbook

List the worksheets in an xlsx workbook

## Usage

``` r
xlsx_sheets(path)
```

## Arguments

- path:

  Path to an `.xlsx` file.

## Value

A character vector of worksheet names, in workbook order. A workbook
always has at least one.

## See also

[zuxlsx-conditions](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md)
for the errors this can raise.

## Examples

``` r
path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")
xlsx_sheets(path)
#> [1] "readings" "notes"   
```
