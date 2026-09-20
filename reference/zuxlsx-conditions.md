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

- `zuxlsx_xml_error`:

  A part of the workbook is not well-formed XML. Raised in preference to
  `zuxlsx_ooxml_error` when the failure is the XML itself rather than
  what it says, and names the part and line.

- `zuxlsx_ooxml_error`:

  The ZIP archive opened but is not a workbook. A valid workbook
  declares at least one worksheet.

- `zuxlsx_sheet_error`:

  The workbook opened, but the requested worksheet is not in it.

- `zuxlsx_encrypted_error`:

  The workbook is password-protected. Its contents are encrypted and
  this package cannot decrypt them. Raised in preference to
  `zuxlsx_unsupported_format_error` so that "needs a password" can be
  handled on its own – it is the one unsupported format the caller can
  do something about.

- `zuxlsx_unsupported_format_error`:

  The file is a spreadsheet, but not one zuxlsx can read: an `.xlsb`,
  whose worksheets are binary rather than XML, or an OLE2 file, which is
  either a legacy `.xls` or an encrypted workbook. Raised in preference
  to reporting such a file as corrupt, which is what it otherwise looks
  like.

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
