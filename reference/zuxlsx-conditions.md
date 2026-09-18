# Conditions raised by zuxlsx

All errors raised by zuxlsx carry a condition class, so that they can be
caught by kind rather than by matching on the message text, which is not
stable. Every class below is a subclass of `zuxlsx_error`.

## Details

- `zuxlsx_input_error`:

  An argument was not usable: a `path` that is not a single string, or a
  file that does not exist.

- `zuxlsx_zip_error`:

  The file could not be opened as a ZIP archive. It is missing,
  unreadable, truncated, or not a ZIP at all.

- `zuxlsx_ooxml_error`:

  The ZIP archive opened but is not a workbook. A valid workbook
  declares at least one worksheet.

- `zuxlsx_memory_error`:

  An allocation failed while reading.

Conditions carry the offending `path` in a `path` element, where one
applies.

## Examples

``` r
tryCatch(
  xlsx_sheets("no-such-file.xlsx"),
  zuxlsx_input_error = function(e) conditionMessage(e)
)
#> [1] "`path` does not exist: no-such-file.xlsx"
```
