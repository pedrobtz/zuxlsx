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

  The workbook is password-protected and no `password` was given. Raised
  in preference to `zuxlsx_unsupported_format_error` so that "needs a
  password" can be handled on its own.

- `zuxlsx_password_error`:

  The `password` given is not the workbook's. A subclass of
  `zuxlsx_encrypted_error`, so one handler covers a password that is
  missing and one that is wrong. A damaged encryption header is
  indistinguishable from a wrong password, by design of the format.

- `zuxlsx_integrity_error`:

  A password-protected workbook is damaged: its encrypted package does
  not match the integrity code stored with it, or its container or
  encryption parameters are inconsistent. Nothing is decrypted from a
  file that fails this check.

- `zuxlsx_unsupported_format_error`:

  The file is a spreadsheet, but not one zuxlsx can read: an `.xlsb`,
  whose worksheets are binary rather than XML; a legacy `.xls`; or a
  workbook encrypted with a scheme other than agile encryption, such as
  Office 2007's standard encryption. Raised in preference to reporting
  such a file as corrupt, which is what it otherwise looks like.

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
