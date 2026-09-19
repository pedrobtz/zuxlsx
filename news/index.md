# Changelog

## zuxlsx 0.1.0

First release. zuxlsx reads `.xlsx` workbooks without a system XML or
ZIP library: it bundles the ‘xlsxio’ reader and links ‘Expat’ and
‘miniz’ statically from `zuxml` and `zukomp`, so an installed zuxlsx has
no run-time dependency on either.

### Reading

- [`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
  reads a worksheet into a data frame, giving each column the type its
  cells support: logical, double, character, `Date` or `POSIXct`.
  `range` takes A1 notation and either corner may name a cell, a column
  or a row, so `"B2:D10"`, `"A:C"` and `"2:10"` are all accepted.

- [`xlsx_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_cells.md)
  returns one row per cell with its position, type, text and numeric
  value – the view underneath
  [`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md),
  for worksheets that are not rectangular enough for a data frame.

- [`xlsx_rows()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_rows.md)
  returns a worksheet row by row as text, padded so that the nth element
  of each row is the nth column.

- [`xlsx_read_cells()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_read_cells.md)
  reads a worksheet a chunk at a time, passing each chunk to a function.
  Returning `FALSE` stops the read, which is how a caller finds
  something near the top of a large worksheet without paying for the
  rest.

- [`xlsx_sheets()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_sheets.md)
  lists worksheets, and
  [`zuxlsx_native()`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx_native.md)
  reports the ‘xlsxio’, ‘Expat’ and ‘miniz’ versions actually linked in.

### Dates

- Both Excel epochs are handled. The workbook’s own `date1904` setting
  decides which is used, so a workbook written on a Mac does not read
  four years out.

- The 1900 system’s phantom 29 February 1900 is accounted for: serial 1
  is 1 January 1900 and serial 61 is 1 March 1900, as Excel shows them,
  and serial 60 – a day that never existed – is `NA`. Using a single
  origin, as is common, puts every date before March 1900 a day early.

### Errors

- Every error is a classed condition under `zuxlsx_error`:
  `zuxlsx_input_error`, `zuxlsx_zip_error`, `zuxlsx_xml_error`,
  `zuxlsx_ooxml_error`, `zuxlsx_sheet_error`,
  `zuxlsx_unsupported_format_error` and `zuxlsx_memory_error`. See
  [`?"zuxlsx-conditions"`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md).

- A file that is a spreadsheet zuxlsx cannot read is reported as such
  rather than as damage. An encrypted workbook is an OLE2 container, not
  a ZIP, and an `.xlsb` stores its worksheets as binary records; both
  raise `zuxlsx_unsupported_format_error` instead of looking corrupt.

- XML that will not parse is distinguished from XML that parses but
  declares no worksheet, and the message names the part and line.
