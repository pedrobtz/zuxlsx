# Changelog

## zuxlsx 0.0.0.9000

- [`xlsx_sheets()`](https://pedrobtz.github.io/zuxlsx/reference/xlsx_sheets.md)
  lists the worksheets in an `.xlsx` file, and
  [`zuxlsx_native()`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx_native.md)
  reports the vendored ‘xlsxio’ version together with the ‘Expat’ and
  ‘miniz’ builds linked in from `zuxml` and `zukomp`. These are a first
  slice rather than the reading API: they exist so the native build is
  exercised by a test.

- Errors are raised as classed conditions: `zuxlsx_input_error`,
  `zuxlsx_zip_error`, `zuxlsx_ooxml_error` and `zuxlsx_memory_error`,
  all subclasses of `zuxlsx_error`. See
  [`?"zuxlsx-conditions"`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md).
  A ZIP archive that is not a workbook is now an error rather than an
  empty result.
