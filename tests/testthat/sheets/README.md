# readxl fixtures

These `.xlsx` files are copied from the tidyverse/readxl test fixture set:

<https://github.com/tidyverse/readxl/tree/main/tests/testthat/sheets>

Copied from commit `47f8aeac0a99eee6c6db2d64ead2225e5e3ae4af`, by way of the
`utopp/pkg-xlsx` prototype. The readxl project is licensed under the MIT
license. See `LICENSE-readxl.md` for the copied license text.

They are real-world interoperability workbooks, and cover part of what design
§17 asks for. The generated per-case corpus under `tests/xlsx/` described in
§17.4 is still to be built; these do not replace it.

| File | What it exercises (verified from the archive contents) |
| --- | --- |
| `blanks.xlsx` | Blank cells and rows; three worksheets, with `sharedStrings.xml` and `styles.xml`. |
| `empty-sheets.xlsx` | A workbook where a worksheet has no cell data. |
| `inlineStr.xlsx` | Inline strings: there is no `xl/sharedStrings.xml` part at all. |
| `missing-v-node-xlsx.xlsx` | Cells written without a `<v>` value node. |
| `no-styles-or-sharedStrings-parts.xlsx` | Both optional parts absent — only `workbook.xml`, its rels, and one worksheet. |
| `nonstandard-xml-ns-prefix.xlsx` | `<sheet>` carries `ns:id` instead of the conventional `r:id`, with the relationships namespace declared locally. Relationship lookup must match on namespace URI, not prefix. |
| `utf8-sheet-names.xlsx` | Non-ASCII worksheet names (`µ`, `∂`). |
