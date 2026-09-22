# zuxlsx: roadmap to v0.1.0

Status: retroactive. Written 2026-09-22 from the git history and
[design-zuxlsx.md](design-zuxlsx.md), after the fact for Stages 0 to 7: those
stages were done before this file existed, so their exit criteria are the ones
the merged pull requests actually met, not ones that were set in advance.
Stages 8 to 10 are the plan from here.

The siblings (`zukomp`, `zuxml`, `zucrypt`, `zuhttp`) each have a roadmap of
this shape. zuxlsx had none, and section **Review 2026-09-22** at the end
records what that cost.

## Rules

- **One pull request per stage** (or a small, named set of them), against
  `main`. The stage's issues are the checklist.
- **A stage ends when its exit criteria pass in CI**, not when its code is
  written. A criterion that cannot be met yet stays unticked and says why.
- **Stages are sequential from Stage 8 on.** An open defect in a stage blocks
  the next one; in particular nothing here is "CRAN-ready" until Stage 8 is
  closed.
- Design sections are cited as §n. When work settles something the design
  left open, the design changes in the same commit.

## Scope of v0.1.0

Read `.xlsx` worksheets from a path into data frames and cells, with classed
errors, both date epochs, and no run-time dependency on any sibling.

Out of v0.1.0: writing workbooks; `.xlsb` (#23); decrypting an encrypted
workbook (#22, targeted at 0.2.0); reading from memory (#25); formula text
(§21).

| Stage | Status |
|---|---|
| Stage 0 — Package identity | complete |
| Stage 1 — Vendor xlsxio and link the sibling archives | complete |
| Stage 2 — Classed errors and adversarial corpus | complete |
| Stage 3 — Typed cell reader | complete |
| Stage 4 — Data frames and dates | complete, one defect carried to Stage 8 (#40) |
| Stage 5 — Interoperability corpus | complete |
| Stage 6 — Formats that are not broken files | complete |
| Stage 7 — Streaming reader and C column builders | complete |
| Stage 8 — Hardening | open |
| Stage 9 — API freeze and docs | open |
| Stage 10 — CRAN release | open, blocked on zuxml and zukomp reaching CRAN |

---

## Stage 0 — Package identity

**Status:** complete.

Evidence: commits 01146b6 (package skeleton) and 8ed3ee9 (pkgdown site), both
before the first pull request.

- [x] A package skeleton that builds, and a pkgdown site.

## Stage 1 — Vendor xlsxio and link the sibling archives

**Status:** complete.

Evidence: #1 (6b34974 vendors xlsxio 0.2.36 with patch 0001; 4d9a59f builds
through `LinkingTo`; 7b57254 quotes the archive paths; a399963 records the
undocumented edit as patch 0002 and adds `tools/vendor/verify`), #11 (c7dd57f
resolves the archives under `R_ARCH` as well as beside it; 300cffa tracks the
siblings at `@main`). It depended on the sibling changes design §4 records as
pedrobtz/zuxml#7 and pedrobtz/zukomp#10.

- [x] `src/vendor/xlsxio/` is pristine 0.2.36 plus declared patches, and
      `tools/vendor/verify` passes.
- [x] `configure`/`configure.win` find `libzuxml.a` and `libzukomp.a` under
      `lib/<r_arch>` or `lib/` and stop with a message when either is missing.
- [x] `xlsx_sheets()` reads the readxl fixtures through both archives
      (`test-linking.R`).

## Stage 2 — Classed errors and adversarial corpus

**Status:** complete.

Evidence: #1 (7b35d66 raises classed conditions and keeps R allocation out of
the callback), #2 (b2d5708: the malformed, hostile and unusual-but-valid
corpora, built in-test), #12 (15ccae8: `zuxlsx_xml_error` naming the part and
line).

- [x] Every error is a subclass of `zuxlsx_error`, asserted by class (§15).
- [x] Adversarial archives are built byte by byte in `helper-zip.R` (§17.4b).

## Stage 3 — Typed cell reader

**Status:** complete.

Evidence: #3 (4b74fb4: patch 0003 exposes the OOXML cell type and whether the
number format is a date; `xlsx_cells()`).

- [x] `xlsx_cells()` classifies every OOXML cell type and recognises date
      number formats (§11, §13).

## Stage 4 — Data frames and dates

**Status:** complete, with one defect carried to Stage 8: a table starting at
row 3 or below takes a blank row as its header (#40).

Evidence: #4 (373433b: `read_xlsx()`, both epochs, patch 0004 for
`date1904`), #5 (63eb79e: the row gap the readxl corpus exposed), #6 (9b72b95:
`range` and `xlsx_rows()`), #10 (add57ce: the example workbook the examples
had been pretending to use).

- [x] `read_xlsx()` builds typed columns; both epochs and the 1900 phantom
      leap day are handled (§11).
- [x] `range` accepts cells, columns and rows as corners (§12).
- [x] Every example runs, against `inst/extdata/two-sheets.xlsx`.

## Stage 5 — Interoperability corpus

**Status:** complete.

Evidence: #5 (the seven readxl workbooks asserted on content), #7 (f7e3884,
05d1d9f: the POI corpus in `tools/corpus/`, run in CI), #8 (ea6acc4: patch
0005, tolerant part names), #16 (0fe662c: patch 0006, strict OOXML, and
`expected.tsv` recording sheet and cell counts), #19 (1644337: ZIP64).

- [x] Committed fixtures are asserted on content, not only on opening.
- [x] The external corpus pins outcome, sheet count and cell count per file,
      and runs on every pull request (`corpus.yaml`).

## Stage 6 — Formats that are not broken files

**Status:** complete.

Evidence: #9 (8a1e9d5: OLE2 and `.xlsb` reported as unsupported formats),
#21 (6172cfe, 136e4bd, 833199a, 0a942f5: a real Agile-encrypted fixture, the
CFB directory classifier, `zuxlsx_encrypted_error`, and the agile-only
decryption scope of §21c).

- [x] An encrypted workbook, a legacy `.xls`, another OLE2 file and an `.xlsb`
      each get their own answer rather than "corrupt archive" (§21a).

## Stage 7 — Streaming reader and C column builders

**Status:** complete.

Evidence: #13 (dc79ce3: `xlsx_read_cells()`), #19 (54cee82: column types
decided in C), #33 (88fe4d4: benchmarks against readxl and openxlsx2).

- [x] A callback that returns `FALSE` stops the read; early termination is
      measured (§12).
- [x] Peak memory measured before and after moving column building to C
      (§14).

## Stage 8 — Hardening

**Status:** open. Fuzzing has started: #20 (ace9a55) found a process crash,
fixed by patch 0007 and reported upstream.

What this stage is for: a malformed, truncated or hostile workbook must end in
a classed condition, promptly, and never in plausible partial data.

- [ ] A malformed or truncated worksheet, and a corrupt DEFLATE stream, raise a
      classed error instead of returning the rows read so far (#38).
- [ ] The CRC-32 of every extracted part is verified, and `test-hostile.R`'s
      KNOWN GAP test is turned into an error expectation (#39).
- [ ] The header and the row extent do not depend on xlsxio's padding: tables
      starting at rows 1, 2, 3 and 10 give the same data frame (#40).
- [ ] Cell coordinates are capped at the sheet limits in the reader and in
      `range`, and the 1.7 KB workbooks that ask for 321 million cells or two
      billion rows fail fast with a classed error (#41).
- [ ] Whole-sheet reads can be interrupted, and no heap memory is held in a
      bare local across an R allocation (#42).
- [ ] zuxlsx's own C (the OLE2 classifier, the cell classifier, the column
      builder) runs under the sanitisers through `tools/fuzz/`, and a
      3000-mutant campaign reports nothing (#45).
- [ ] xlsxio's parsers install a DOCTYPE handler (#47, companion of
      pedrobtz/zuxml#41).
- [ ] CI runs `tools/vendor/verify`, the fixture generators' `--check`,
      sanitizers and pinned r-actions, and tests or raises the `R (>= 4.1)`
      floor (#44).
- [ ] `inst/COPYRIGHTS` describes the seven patches it lists (#48).

## Stage 9 — API freeze and docs

**Status:** open. The documentation refreshes in #35, #36 and #37 describe
the package as it is; what remains is the public surface itself.

- [ ] The exported names are decided before CRAN makes them permanent, and
      the decision is recorded in §12 (#46).
- [ ] `xlsx_rows()` is linear in the size of the sheet, or is cut from 0.1.0
      (#43).
- [ ] `col_types` (#27) is either in 0.1.0 or explicitly deferred, with the
      fate of `zuxlsx_type_error` decided either way.
- [ ] A decision on `na`, `skip` and `n_max` for `read_xlsx()`, recorded in
      §12.
- [ ] A getting-started article (#29).
- [ ] The user-facing docs that describe an older package are corrected (#48).

## Stage 10 — CRAN release

**Status:** open, blocked on zuxml and zukomp reaching CRAN. The paperwork
that could be done early was: #14 (9f113a2).

The steps, and why their order is fixed, are in
[release-checklist.md](release-checklist.md). In short:

- [ ] zuxml and zukomp are on CRAN, and their CRAN builds install the static
      archives.
- [ ] Stages 8 and 9 are closed.
- [ ] On submission day: `Remotes:` dropped, README install switched,
      `R CMD check --as-cran` re-run after the edit, plus win-builder and a
      CRAN-like container, all 0/0/0.
- [ ] Tag v0.1.0 and submit.

---

## After v0.1.0

**0.2.0 — agile decryption (#22).** Needs, in this repository: reading from
memory (#25), documented resource limits including the spin count and the
decrypted size (#26), and the fuzzed native C of #45, since the CFB stream
reader extends the classifier it covers. Needs from zucrypt: its static
archive linked as a third archive, and zucrypt on CRAN before zuxlsx 0.2.0 is
submitted. And, from design §21c: payload integrity (HMAC) verified before any
plaintext reaches the ZIP reader, and a password API. Standard (ECB)
encryption stays out of scope; pedrobtz/zucrypt#29 removes the ECB it no
longer needs.

**Unscheduled:**

- #15 — detect a stale static link, including `libzucrypt.a` once it is
  linked.
- #24 — ZIP archives with no central directory. Likely won't-fix: §17.3a
  records the refusal as correct, and reading local headers conflicts with the
  rule that the first central-directory entry wins for a duplicated part.
- #23 — `.xlsb`. Icebox: it needs its own design section and cannot be built
  on xlsxio.
- #28; #30 and #31 together; #32 (which depends on #46).

**Watched in other repositories:** pedrobtz/zukomp#37 (hostile coverage of the
ZIP reader this package links), and pedrobtz/zukomp#35 and pedrobtz/zuxml#39,
which will build zuxlsx at `@main` in their CI.

---

## Review 2026-09-22

- **"CRAN-ready" was declared before the hardening happened.** #14 set 0.1.0
  and wrote NEWS on 2026-09-19. After it came strict OOXML (#16, four real
  workbooks that had been reading as empty), fuzzing (#20, a process crash from
  one flipped byte), ZIP64 and the encrypted-workbook classifier (#19, #21),
  and #38 to #42 are still open. A stage gate would have put hardening before
  the release paperwork.
- **The design doc became the status tracker.** Dated status blocks piled up
  in the sections they describe, until §14 had two that disagreed, §21's sat
  under §21c, and §17.4e called the fixture tree complete while §16 listed what
  it lacked. A roadmap is where status belongs; the design should say what is
  true.
- **Without exit criteria, a list in the design was a reading list.**
  `malformed_sheet_xml.xlsx` was in §17.4 from day one and was never built;
  had it been an exit criterion, #38 would have been found in Stage 2.
- **The corpus pins whatever the reader produced.** `expected.tsv` catches a
  change against the baseline, and it caught the strict-OOXML emptiness once
  cell counts were added, but a read that was already truncated when the
  baseline was recorded is locked in as expected. It needs a one-off
  differential: the count of `<c>` elements carrying a value, from an
  independent pass over each worksheet, compared with the cells the reader
  returns.
- **xlsxio is a good starting point and a poor long-term owner of the
  worksheet parser.** Of the seven patches only 0001 is the ZIP backend §22
  expected; the rest fix or add core OOXML handling, and the open defects
  (#38, #40, #41) are in xlsxio's worksheet code. §22 now records the trigger
  for replacing that parser with one of this package's own: ten patches, or
  the first upstream bump that does not apply cleanly.
- **Tracking the siblings at `@main` means CI never builds what CRAN will.**
  It cost one Windows break (fixed in c7dd57f the same day), and after the
  siblings reach CRAN it needs a leg against their CRAN releases, with `@main`
  kept as a canary.
