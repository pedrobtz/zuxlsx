# Releasing zuxlsx to CRAN

Everything here that could be done early has been. What remains is either
blocked on something outside this repository, or would break installation if
done before submission day.

## Blocked: the siblings must be on CRAN first

`LinkingTo: zukomp, zuxml`, and **CRAN ignores `Remotes:`** -- it is a
devtools and remotes field, not an R one. A submission made while those two
are only on GitHub fails at incoming checks, before a human sees it, because
the declared dependencies cannot be installed from CRAN.

So the order is fixed: `zuxml` and `zukomp` are accepted, then zuxlsx is
submitted. Nothing in this package can shorten that.

Check with:

```r
p <- rownames(available.packages(repos = "https://cloud.r-project.org"))
c("zuxml", "zukomp") %in% p
```

## Do these on submission day, not before

Both break the GitHub install path, so they are last.

1. **Drop `Remotes:` from `DESCRIPTION`.** Until the siblings are on CRAN it
   is the only thing that lets `pak::pak("pedrobtz/zuxlsx")` find them, and
   removing it early breaks continuous integration here as well, since
   `setup-r-dependencies` resolves through it.

2. **Change the README install instructions** from
   `pak::pak("pedrobtz/zuxlsx")` to `install.packages("zuxlsx")`. Doing this
   before acceptance documents something that does not work.

Then re-run `R CMD check --as-cran` -- dropping `Remotes:` changes how the
dependencies resolve, so the check that matters is the one after the edit.

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

- `tools/vendor/verify` and `tools/fixtures/make-extdata.R --check`, so the
  vendored tree and the generated fixture still match what is recorded.
- That the minimum sibling version named in `configure` is still right. It
  says `0.1.0`, which is what shipped the archives; a later release that
  changed their location would need it revisited.
