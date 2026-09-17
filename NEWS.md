# zuxlsx 0.0.0.9000

* `xlsx_sheets()` lists the worksheets in an `.xlsx` file, and
  `zuxlsx_native()` reports the vendored 'xlsxio' version together with the
  'Expat' and 'miniz' builds linked in from `zuxml` and `zukomp`. These are a
  first slice rather than the reading API: they exist so the native build is
  exercised by a test.
