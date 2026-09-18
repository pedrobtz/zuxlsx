# zuxlsx: Read 'xlsx' Workbooks Without System Dependencies

Reads spreadsheet data from 'xlsx' workbooks using a bundled copy of the
'xlsxio' reader (<https://github.com/brechtsanders/xlsxio>), so that no
system XML or ZIP library is required. The 'Expat' parser and the
'miniz' ZIP reader are linked statically at install time from the
'zuxml' and 'zukomp' packages, which means there is no run-time
dependency on either of them. Worksheets are read as a stream, so a
workbook does not have to be held in memory in full. Writing workbooks
is out of scope.

## See also

Useful links:

- <https://github.com/pedrobtz/zuxlsx>

- <https://pedrobtz.github.io/zuxlsx/>

- Report bugs at <https://github.com/pedrobtz/zuxlsx/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Other contributors:

- Brecht Sanders (xlsxio, bundled in src/vendor/xlsxio) \[copyright
  holder\]
