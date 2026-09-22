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

The first two break the GitHub install path, so they are last.

1. **Drop `Remotes:` from `DESCRIPTION`.** Until the siblings are on CRAN it
   is the only thing that lets `pak::pak("pedrobtz/zuxlsx")` find them, and
   removing it early breaks continuous integration here as well, since
   `setup-r-dependencies` resolves through it.

2. **Change the README install instructions** from
   `pak::pak("pedrobtz/zuxlsx")` to `install.packages("zuxlsx")`. Doing this
   before acceptance documents something that does not work.

3. **Re-run the checks after those two edits**, not before -- dropping
   `Remotes:` changes how the dependencies resolve, so the checks that matter
   are the ones after the edit:
   - `R CMD check --as-cran` locally, against the siblings' CRAN releases;
   - win-builder (R-devel and R-release), which is CRAN's own Windows build
     rather than a GitHub runner's approximation of it;
   - a CRAN-like container (R-hub's clang or gcc-16 images, with
     `-pedantic`), since the vendored xlsxio is compiled by nothing but this
     package's own checks, and none of them uses CRAN's r-devel compilers
     today (#44).

   All three at 0 errors, 0 warnings, and no NOTE beyond "New submission".

This whole file is Stage 10 of [roadmap.md](roadmap.md), which also requires
Stages 8 (hardening) and 9 (API freeze) to be closed first.

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
- That the siblings' *CRAN* builds install the archives where `configure`
  looks: `lib/libzuxml.a` for zuxml, `lib${R_ARCH}/libzukomp.a` for zukomp.
  `configure` names no sibling version and must not -- zuxml 0.1.0 exists both
  with and without the archive, so it checks for the file -- and it asks for
  `lib/<r_arch>` before plain `lib/`, which is right for either convention.
  Check the files in a CRAN-installed copy, not the version number. Whether to
  add `LinkingTo:` version floors naming those CRAN releases is a decision to
  make at the same time.
- That `inst/COPYRIGHTS` still describes the patch set in
  `tools/patches/xlsxio/`. `tools/vendor/verify` checks the patch names but not
  the prose around them, which is how it came to say "two local patches"
  above a list of seven (#48).
