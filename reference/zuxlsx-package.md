# zuxlsx: Read 'xlsx' Workbooks Without System Dependencies

Reads spreadsheet data from 'xlsx' workbooks using a bundled copy of the
'xlsxio' reader (<https://github.com/brechtsanders/xlsxio>), so that no
system XML or ZIP library is required. The 'Expat' parser, the 'miniz'
ZIP reader and the 'TF-PSA-Crypto' cryptography used to open
password-protected workbooks are linked statically at install time from
the 'zuxml', 'zukomp' and 'zucrypt' packages, which means there is no
run-time dependency on any of them. Worksheet XML is parsed as a stream
rather than loaded whole; the shared-string table and the cells being
returned are held, and a password-protected workbook is decrypted into
memory first. Writing workbooks is out of scope.

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
