# Releasing zuxlsx to CRAN

Everything here that could be done early has been. What remains is either
blocked on something outside this repository, or would break installation if
done before submission day.

## Cleared: the siblings are on CRAN

`LinkingTo: zucrypt, zukomp, zuxml`, and **CRAN ignores `Remotes:`** -- it is
a devtools and remotes field, not an R one -- so a submission made while any
of the three was only on GitHub would have failed at incoming checks.

That block is gone: zukomp 0.1.0 (2026-10-16), zucrypt 0.1.0 (2026-10-23) and
zuxml 0.1.0 (2026-10-27) are all on CRAN, and each CRAN build installs its
`lib/` archive. On 2026-10-28 `R CMD check --as-cran` passed against those
three CRAN builds, with `Remotes:` removed, in the C locale: only the
"New submission" NOTE.

```r
p <- rownames(available.packages(repos = "https://cloud.r-project.org"))
c("zuxml", "zukomp", "zucrypt") %in% p
```

## Done for submission (2026-10-28)

- `Remotes:` is dropped from `DESCRIPTION`. With all three siblings on CRAN,
  `setup-r-dependencies` and `pak::pak("pedrobtz/zuxlsx")` resolve them from
  there; development no longer builds against their `main`.
- The README's install instructions say `install.packages("zuxlsx")`, with
  the GitHub install kept as the development version.
- CI is the shared `pedrobtz/r-actions` workflows: `R-CMD-check.yaml` (with
  Windows R-devel and `nosuggests`), `native-checks.yaml` (sanitizers,
  valgrind, rchk, gctorture, LTO, analyzers, CRAN's special checks) and
  `vendor.yaml`.
- `cran-comments.md` names all three `LinkingTo` packages, TF-PSA-Crypto's
  licence, the one NOTE and the CI test environments.
- `Language: en-GB` and `inst/WORDLIST`; `spelling::spell_check_package()`
  is clean.

What is left is the submission itself: a green full-profile run on the
commit being submitted, then `devtools::submit_cran()`.

## Already done

- `inst/COPYRIGHTS` covers every copyright holder, including Expat and miniz,
  which are linked statically and so redistributed in the built package even
  though their source is not here. Full texts are installed under
  `inst/licenses/`.
- `cran-comments.md` explains the `LinkingTo`-without-`Imports:` arrangement,
  the bundled and linked third-party code, and the absence of method
  references.
- `NEWS.md` documents 0.1.0.
- Version is 0.1.0 rather than a development version.
- Every exported function has `@return` and runnable `@examples`; no
  `\dontrun{}`, nothing commented out.
- `urlchecker::url_check()` is clean; all URLs are https and none redirect.
- LICENSE year is current.

## Worth re-checking at the time

- That the tests pass in a locale that is not UTF-8
  (`LANG=C LC_ALL=C Rscript -e 'devtools::test()'`). CRAN's Debian clang
  machine runs them that way, and CI here does not; a non-ASCII password
  literal once failed only there.
- `tools/vendor/verify` and `tools/fixtures/make-extdata.R --check`, so the
  vendored tree and the generated fixture still match what is recorded.
- That the minimum sibling version named in `configure` is still right. It
  says `0.1.0`, which is what shipped the archives; a later release that
  changed their location would need it revisited.
