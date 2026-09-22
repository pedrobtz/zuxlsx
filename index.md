# zuxlsx

Read `.xlsx` workbooks from R with no system XML or ZIP library
required.

zuxlsx bundles the [xlsxio](https://github.com/brechtsanders/xlsxio)
reader and links the Expat parser and the miniz ZIP reader statically at
install time, out of the sibling packages
[zuxml](https://github.com/pedrobtz/zuxml) and
[zukomp](https://github.com/pedrobtz/zukomp). Those are `LinkingTo`
dependencies only: the archives end up inside `zuxlsx.so`, so neither
package has to be installed or loadable once zuxlsx is built.

Writing workbooks is out of scope.

## Usage

``` r

library(zuxlsx)

path <- system.file("extdata", "two-sheets.xlsx", package = "zuxlsx")

xlsx_sheets(path)                      # "readings" "notes"
read_xlsx(path)                        # first worksheet as a data frame
read_xlsx(path, sheet = "readings", range = "A1:B3")
```

[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md)
gives each column the type its cells support: logical, double,
character, `Date` or `POSIXct`. A column that cannot hold its cells
becomes character rather than failing. `range` takes A1 notation, and
either corner may name a cell, a column or a row, so `"B2:D10"`, `"A:C"`
and `"2:10"` are all accepted.

Both Excel date systems are handled. The workbook’s own `date1904`
setting decides which is used, and the 1900 system’s phantom 29 February
1900 is accounted for, so dates before March 1900 are not a day early.

Underneath, for worksheets that are not rectangular enough for a data
frame:

``` r

xlsx_cells(path)     # one row per cell: position, type, text, numeric value
xlsx_rows(path)      # a worksheet row by row as text, padded to a rectangle

# A chunk at a time; returning FALSE stops the read, so finding something
# near the top of a large worksheet does not pay for the rest.
xlsx_read_cells(path, callback = function(cells) { str(cells); FALSE })
```

## Installation

zuxlsx needs `zuxml` and `zukomp` at build time, and its `configure`
script will stop with an explanatory message if their static archives
are missing. `pak` picks them up from the `Remotes:` field:

``` r

# install.packages("pak")
pak::pak("pedrobtz/zuxlsx")
```

## Errors

Every error carries a condition class, so calling code can tell a
corrupt archive from a missing file without matching on message text:

``` r

tryCatch(
  xlsx_sheets("broken.xlsx"),
  zuxlsx_zip_error   = function(e) "not a readable ZIP archive",
  zuxlsx_ooxml_error = function(e) "a ZIP, but not a workbook",
  zuxlsx_error       = function(e) "something else went wrong"
)
```

See
[`?"zuxlsx-conditions"`](https://pedrobtz.github.io/zuxlsx/reference/zuxlsx-conditions.md)
for the full list.

## Third-party code

The bundled xlsxio reader is MIT licensed and is never edited in place.
It is re-derived from the pristine 0.2.36 release archive plus the
patches in `tools/patches/xlsxio/`, and `tools/vendor/verify` checks
offline that the committed tree, the manifests and the attribution all
still agree.
