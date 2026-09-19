## R CMD check results

0 errors | 0 warnings | 0 notes

Checked with `--as-cran` on macOS (R release) and, through GitHub Actions, on
Ubuntu (R devel, release and oldrel-1), macOS and Windows.

A first submission usually draws a "New submission" NOTE, which is expected.

## Dependencies

zuxlsx has no `Imports:` and no `SystemRequirements:`. It has `LinkingTo:
zukomp, zuxml`, and both are used only at build time: their static archives
are linked in, so neither package has to be installed for zuxlsx to load or
run. This is deliberate -- the point of the package is to read `.xlsx` files
without a system XML or ZIP library -- and it is why the two appear under
`LinkingTo:` alone rather than also under `Imports:`.

`configure` and `configure.win` resolve those archives with
`system.file("lib", .Platform$r_arch, package = ...)` and stop with an
explanatory message if they are absent, rather than failing at link time.

## Bundled and linked third-party code

`src/vendor/xlsxio/` contains a reduced copy of the xlsxio reader (MIT), with
five local patches recorded in `tools/patches/xlsxio/`. Expat and miniz are
not bundled, but are linked statically and are therefore redistributed in the
built package; both are MIT.

`inst/COPYRIGHTS` lists every copyright holder and what each covers, and the
full licence texts of the linked libraries are installed under
`inst/licenses/`. The vendored tree's provenance -- upstream release, commit,
archive checksum and per-file checksums -- is in `tools/vendor/`, and can be
re-verified offline.

## Method references

There are no published references describing the methods in this package. It
implements reading of the ECMA-376 / ISO IEC 29500 SpreadsheetML format, which
is a file format specification rather than a method.

## Test corpus

The package's own tests are self-contained and run in a few seconds. A larger
interoperability corpus drawn from another project is exercised in continuous
integration only; it lives under `tools/corpus/`, is excluded from the build by
`.Rbuildignore`, and no file from it is redistributed.
