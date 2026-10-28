## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new submission.

## Test environments

Through GitHub Actions, using the reusable workflows in
<https://github.com/pedrobtz/r-actions>:

* macOS, Windows and Ubuntu, R release
* Windows, R devel
* Ubuntu, R oldrel-1 and R 4.1 (the minimum in `Depends:`)
* the r-devel Linux containers `clang23`, `ubuntu-clang` and `ubuntu-gcc16`
* `nosuggests`: the suite with no suggested package installed
* AddressSanitizer and UBSan (gcc and clang), valgrind, rchk, gctorture, LTO
  and gcc's `-fanalyzer`
* CRAN's additional checks: rcnst, rlibro and vnu

And locally on macOS with R 4.5.2, `--as-cran`, against the CRAN releases of
zuxml, zukomp and zucrypt, in the C, ISO-8859-1 and UTF-8 locales.

## Dependencies

zuxlsx has no `Imports:` and no `SystemRequirements:`. It has `LinkingTo:
zucrypt, zukomp, zuxml`, and all three are used only at build time: their
static archives are linked in, so none of them has to be installed for zuxlsx
to load or run. This is deliberate -- the point of the package is to read
`.xlsx` files without a system XML, ZIP or cryptography library -- and it is
why the three appear under `LinkingTo:` alone rather than also under
`Imports:`. zucrypt is also in `Suggests:`, because some tests call its R
functions to build encrypted inputs; they skip without it.

`configure` and `configure.win` resolve those archives with
`system.file("lib", .Platform$r_arch, package = ...)` and stop with an
explanatory message if they are absent, rather than failing at link time.

## Bundled and linked third-party code

`src/vendor/xlsxio/` contains a reduced copy of the xlsxio reader (MIT), with
eight local patches recorded in `tools/patches/xlsxio/`. Its author is listed
in `Authors@R` as a copyright holder.

Expat (MIT), miniz (MIT) and TF-PSA-Crypto (Apache-2.0) are not bundled, but
are linked statically from the three packages above and are therefore
redistributed in the built package. `inst/COPYRIGHTS` lists every copyright
holder and what each covers, and the full licence texts of the linked
libraries are installed under `inst/licenses/`. The vendored tree's
provenance -- upstream release, commit, archive checksum and per-file
checksums -- is in `tools/vendor/`, and can be re-verified offline.

## Method references

There are no published references describing the methods in this package. It
implements reading of the ECMA-376 / ISO/IEC 29500 SpreadsheetML format and
the decryption scheme of the [MS-OFFCRYPTO] specification, which are file
format specifications rather than methods.

## Test corpus

The package's own tests are self-contained and run in a few seconds. A larger
interoperability corpus drawn from another project is exercised in continuous
integration only; it lives under `tools/corpus/`, is excluded from the build by
`.Rbuildignore`, and no file from it is redistributed.
