# Fuzzing the native reader

Structure-aware mutation of xlsx workbooks, read under AddressSanitizer and
UndefinedBehaviorSanitizer. Design section 18.

Nothing here ships: `tools/fuzz` is excluded by `.Rbuildignore`, and it needs
a compiler configuration `R CMD check` does not provide.

```sh
./tools/fuzz/build          # compile the harness with both sanitisers
./tools/fuzz/run [count]    # generate mutants and read them (default 500)
./tools/fuzz/harness FILE   # read one file, for reproducing a finding
```

## Why a separate harness rather than the package's own tests

The package's tests run inside R, and R is not built with a sanitiser here --
nor on most machines. A heap overflow that does not happen to land on
something fatal produces a *passing* test: a value comes back, it looks
plausible, and nothing reports that the read walked off the end of a buffer.

`harness.c` drives the same calls `src/zuxlsx.c` makes, including the
accessors the vendored patches add, so the C can be exercised with a
sanitiser watching and no R in the way. A path the harness does not take is a
path the sanitiser does not check, which is why it reads cells rather than
stopping at the sheet list.

## Why structure-aware rather than flipping bytes in the file

An `.xlsx` is a ZIP of XML parts. Mutating the file as a flat byte stream is
nearly useless against that: almost every edit breaks the archive before a
parser is reached, the reader refuses it immediately, and nothing interesting
runs. `mutate.R` unpacks, mutates one part, and repacks, which keeps the
container valid and aims the damage at the code that has to cope with it.

Measured on a sample run: every mutant opened as an archive, and about two
thirds produced cells -- that is, reached the worksheet parser rather than
dying at the front door.

Parts are chosen from the ones with logic behind them -- `workbook.xml`, the
relationship parts, `sharedStrings.xml`, `styles.xml`, the worksheets,
`[Content_Types].xml` -- and the mutations are: flip bytes, truncate, append
junk, substitute extreme values into numeric attributes, unbalance the XML,
drop the part, and duplicate it under the same name.

## Errors are not findings

Most mutants are malformed on purpose, and refusing them is correct. `run`
does not care whether a file reads. What it reports is a *sanitiser* report:
an out-of-bounds access, a use after free, or undefined behaviour, whether or
not the read also produced a wrong answer or crashed.

Findings are kept in `work/findings/` with the sanitiser output beside each.

## Reproducibility

Each mutant is generated from `set.seed(index)`, so mutant N is the same file
every time from the same seed workbook. A finding is reproducible by its
index; the binary does not need to be kept.

## What it has found

**A NULL dereference that crashed the process**, at mutant 2421 of a 3000-run,
from a single byte flipped in `xl/_rels/workbook.xml.rels` -- `Id="rId1"`
became `Kd="rId1"`. xlsxio compared the missing attribute with `strcasecmp`,
which does not accept NULL, so a `<Relationship>` with a worksheet `Type` and
no `Id` segfaulted. A 1573-byte workbook ended the R session outright, with no
condition raised and nothing to catch.

Fixed by `tools/patches/xlsxio/0007-null-relationship-id-crash.patch`, and
regression-tested from a minimal reproducer rather than from the mutant. The
same campaign afterwards reports nothing.

Upstream xlsxio is affected.
