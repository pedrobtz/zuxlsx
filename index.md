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

## Status

**Early. This is a build slice, not the reading API.**

Two functions exist so far, and they are there mainly so that a broken
native build fails a test rather than being discovered later:

``` r

library(zuxlsx)

xlsx_sheets(path)   # worksheet names, in workbook order
zuxlsx_native()     # the xlsxio, Expat and miniz versions actually linked in
```

[`read_xlsx()`](https://pedrobtz.github.io/zuxlsx/reference/read_xlsx.md),
the cell reader and the column builders are not written yet. The design
they will follow is in `.agents/design-zuxlsx.md`.

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
