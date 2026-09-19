# External interoperability corpus

Workbooks written by other projects, read to find out what this reader gets
wrong. Design sections 17.2 and 17.3.

Nothing here ships. `tools/corpus` is excluded by `.Rbuildignore`, and the
files themselves are not committed — 20 MB of another project's fixtures does
not belong in this repository's history, and CRAN should not pay for it on
every check. What is committed is enough to reproduce the corpus exactly:

| file | what it is |
| --- | --- |
| `sources.tsv` | each upstream, pinned to a commit, with its licence |
| `checksums.sha256` | every file's sha256; also the list of what to fetch |
| `expected.tsv` | what the reader currently makes of each file |
| `fetch` | downloads whatever is missing or stale into `files/`, then verifies all of it |
| `run` | reads everything and reports outcomes that **changed** |
| `sweep.R` | the reader driver behind `run` |

```sh
./tools/corpus/fetch           # download and verify (needs network)
./tools/corpus/fetch --check   # re-verify what is already there
./tools/corpus/run             # compare against expected.tsv
./tools/corpus/run --record    # rewrite expected.tsv
```

`fetch` skips a file only when it is already present *and* its checksum
matches, so it can be pointed at a partly populated `files/` and will download
just the difference. CI relies on that: `corpus.yaml` caches `files/` under a
key derived from `checksums.sha256`, so a run fetches nothing unless the
corpus itself changed, and an older cache restored through `restore-keys`
costs only the delta. Testing mere existence would break that, since an
upstream file rewritten under the same name would be kept and then fail
verification with no way for a re-run to recover.

## Why outcomes rather than passes

Errors are not failures. The corpus deliberately contains truncated archives,
fuzzer-minimised testcases, encrypted workbooks and files that are not
workbooks at all, so "this file errors" is often the correct result. What
matters is whether a file's outcome *changed*, which is what `run` reports and
`expected.tsv` pins.

Record a new baseline only when the change is understood and intended.

## Relationship to `tests/testthat/`

This corpus finds bugs; the package's own suite keeps them fixed. When a file
here exposes a defect, the fix belongs in `tests/testthat/` as a minimal
committed fixture of a few kilobytes, not by shipping the original workbook.
That way the regression is caught on every platform CRAN checks, forever, and
this corpus stays free to grow.

## Sources

**Apache POI** `test-data/spreadsheet`, Apache-2.0. 352 `.xlsx` files: bug
regressions named after their issue number, clusterfuzz-minimised testcases,
and structural oddities. Notices stay with POI; nothing is redistributed here.

**SheetJS `test_files` is not used.** It was the obvious first choice, and it
is unavailable: GitHub has disabled the repository under its Terms of Service,
flagged `private_information`, and the tarball 404s. Even were a mirror found,
vendoring files removed for containing personal data into a package is not a
reasonable thing to do. Recorded here so the question is not reopened blindly.
