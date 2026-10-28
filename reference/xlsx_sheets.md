# List the worksheets in an xlsx workbook

List the worksheets in an xlsx workbook

## Usage

``` r
xlsx_sheets(path, password = NULL)
```

## Arguments

- path:

  Path to an `.xlsx` file.

- password:

  The password of a password-protected workbook, or `NULL` (the default)
  for one without. The workbook is decrypted in memory and never written
  to disk. Agile encryption – what Excel has written since 2013 – is
  supported; the older standard encryption is not, and is reported as
  such. Ignored for a workbook that is not encrypted. R cannot erase a
  string, so the password may stay in memory after the call.

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
