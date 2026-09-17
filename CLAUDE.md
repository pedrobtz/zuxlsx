# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`zuxlsx` is an R package for **reading `.xlsx` workbooks** with no system XML or ZIP dependency, built on the sibling `zu*` packages: `zuxml` (Expat-backed XML) and `zukomp` (miniz-backed DEFLATE), with vendored `xlsxio` supplying the OOXML logic.

## Current state: it builds and reads workbooks

The native stack compiles, links and runs: `xlsx_sheets()` opens a real `.xlsx` and lists its worksheets, which means miniz (from `zukomp`) opened the ZIP, Expat (from `zuxml`) parsed `xl/workbook.xml`, and vendored xlsxio drove both. `devtools::check()` is 0/0/0 and 11 tests pass.

**This is a build slice, not the reading API.** `read_xlsx()`, the cell event model and the column builders (design §12–§14) are unstarted, and `DESCRIPTION` still carries the placeholder Title/Description/Authors. The two exported functions exist so that a broken native build is a failing test rather than something discovered later:

- `xlsx_sheets(path)` — exercises both archives on a real file.
- `zuxlsx_native()` — reports `xlsxio` 0.2.36, `expat_2.8.4`, miniz `11.3.2`. It calls `XML_ExpatVersion()` rather than reading a macro, so a header on the include path without the archive behind it fails at link time.

The build:

- [configure](configure) / [configure.win](configure.win) resolve `system.file("lib", package = ...)` for `zuxml` and `zukomp` and substitute them into [src/Makevars.in](src/Makevars.in). `LinkingTo` puts the *headers* on the path by itself (`CLINK_CPPFLAGS`); there is no equivalent for a library, and the alternatives are worse — `$(shell …)` would force `SystemRequirements: GNU make`, and an `Imports:` entry would add a runtime dependency that nothing needs, since the archives are linked statically.
- `DESCRIPTION` has `LinkingTo: zukomp, zuxml` and **no `Imports:`**, which is what design §3 asks for.
- **`Remotes:` currently pins the two PR branches.** When pedrobtz/zuxml#7 and pedrobtz/zukomp#10 merge, drop the `@branch` suffixes; before any CRAN submission, drop `Remotes:` entirely.
- `src/Makevars` is generated and `.gitignore`d. `cleanup` removes it.

Vendored and copied from the working `utopp/pkg-xlsx` prototype at `/Users/pbtz/Documents/repos/gh/utopp/pkg-xlsx`:

- [src/vendor/xlsxio/](src/vendor/xlsxio/) — xlsxio 0.2.36, **reader only** (`xlsxio_read.c`, `xlsxio_read_sharedstrings.c`, headers, `LICENSE.txt`). The writer is not bundled; writing is out of scope (§21). Upstream CRLF line endings are kept deliberately.
- [tools/patches/xlsxio/0001-miniz-zip-backend.patch](tools/patches/xlsxio/0001-miniz-zip-backend.patch) — **design §5's "main adaptation cost" is already solved.** It adds a `USE_MINIZ` backend beside xlsxio's minizip/minizip-ng/libzip ones, mapping `unzOpen`/`unzLocateFile`/`unzReadCurrentFile` onto `mz_zip_reader_init_file` / `_locate_file_v2` / `_extract_iter_read`. Verified: it applies cleanly to pristine 0.2.36 and reproduces the committed copy byte for byte. Provenance is in [tools/vendor/manifest.tsv](tools/vendor/manifest.tsv), [tools/vendor/checksums.sha256](tools/vendor/checksums.sha256) and [inst/COPYRIGHTS](inst/COPYRIGHTS).
- [tests/testthat/sheets/](tests/testthat/sheets/) — seven readxl interoperability workbooks (inline strings, missing parts, nonstandard namespace prefix, UTF-8 sheet names, blanks), MIT, with provenance and a per-file manifest in that directory's README. The generated §17.4 corpus is still to be built.
- [.agents/reference-native-api.md](.agents/reference-native-api.md) — function map of the xlsxio reader, Expat and miniz ZIP APIs the vendored code uses.

The prototype also holds a `USE_MINIZ` patch for `xlsxio_write.c`, a working `src/bindings.c` + `R/xlsxio.R` read/write path, and research notes (`ROADMAP.md`, `calamine.md`, `libs.md`). None of that was copied; go back for it if writing or a quick end-to-end spike is wanted.

Everything else described below is unstarted.

## The design doc is the spec

[.agents/design-zuxlsx.md](.agents/design-zuxlsx.md) is binding, not background — §1–§23 cover the dependency model, the miniz ZIP backend adaptation, the streaming pipeline, the cell/column abstractions, the error classes, and the test corpus layout. Read the relevant section before writing code. If implementation shows the design is wrong, **change the design doc in the same commit** rather than diverging silently.

## Where the design doc and reality currently disagree

The doc was written before `zuxml` and `zukomp` reached v1, and three of its assumptions do not hold against the installed packages. They determine the whole native layer, and the decision on them is recorded at the end of this section.

- **§3/§7 "`LinkingTo` only, no `R_GetCCallable()`" is not how those packages work.** `zuxml/inst/include/zuxml.h` and `zukomp/inst/include/zukomp-r.h` document the opposite contract: `Imports:` + `LinkingTo:`, resolving a versioned function table at runtime (`zuxml_api_get()` → `R_GetCCallable("zuxml", "zuxml_api_v2")`; `zukomp_api()` → `zukomp_get_api`). That is the supported path.
- **§4 `inst/lib/libzuxml.a` / `libzukomp.a` do not exist**, and neither package installs `expat.h` or `miniz.h`. `inst/include/` contains only `zuxml.h`, `zukomp.h`, `zukomp-r.h` — deliberately standalone-C99 headers naming no vendored type. So xlsxio cannot be handed the raw Expat API as §4 assumes.
- **§5 assumes miniz's ZIP reader is available through `zukomp`. It is not.** `zukomp/src/Makevars` compiles miniz with `-DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_STDIO`, and zukomp's own `test-abi.R` asserts no `mz_zip_*` symbol is exported. zukomp gives raw DEFLATE/zlib/gzip over memory buffers only — no central directory, no local headers, no entry lookup.

Neither dependency is installed in the local R library. Install from the sibling checkouts (`~/src/github.com/pedrobtz/zuxml`, `.../zukomp`) before anything native can build.

**The vendored xlsxio makes this concrete.** It `#include`s `<expat.h>` and calls `XML_ParserCreate`/`XML_GetBuffer`/`XML_ParseBuffer`/`XML_StopParser` directly, and under `USE_MINIZ` it calls `mz_zip_*` directly. Neither symbol set is reachable through `LinkingTo: zuxml, zukomp` today.

**Decided (2026-09-17): widen the siblings to match the design, rather than changing the design.** The work is done and open as pull requests, both verified against this repo's vendored xlsxio:

- **pedrobtz/zuxml#7** — installs `expat.h`/`expat_external.h` and ships `inst/lib/libzuxml.a` (the Expat objects, no R glue). `XML_StopParser`/`XML_ResumeParser` are in it, which is what xlsxio's row/cell and sheet-list iterators need.
- **pedrobtz/zukomp#10** — ships `inst/lib/libzukomp.a` with miniz's ZIP reader, plus `miniz.h`. It compiles `miniz.c` a *second* time rather than widening the trim, so `zukomp.so` still exports no `mz_zip_*` symbol and `test-abi.R` needed no relaxing. `MINIZ_NO_TIME` also had to go for the archive build, or `mz_zip_archive_file_stat.m_time` is miniz's `m_padding`.

Proven end to end before the PRs were opened: `src/vendor/xlsxio/` compiles against those installed headers, links both archives, and reads the fixtures in [tests/testthat/sheets/](tests/testthat/sheets/) — inline strings, UTF-8 sheet names, and a workbook with no `sharedStrings.xml` part.

**`zuxlsx` still cannot have a `src/Makevars` until both merge and are installed.** When writing it: a `configure` script resolving `system.file("lib", package = ...)` into `Makevars.in` keeps this `LinkingTo`-only, with no `Imports:` and no GNU make (each sibling's README has the snippet). Required defines: `-DXML_STATIC` (Windows) and `-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES` (everywhere — miniz would otherwise `#define` `compress`/`crc32`/`adler32` over any translation unit that also sees R's headers).

Rejected alternatives, for the record: vendoring Expat and miniz here as well (compiles today, but duplicates the siblings and contradicts §3/§6), and retargeting xlsxio onto the `zux_parser_*` wrapper API (blocked on `zuxml` having no `XML_StopParser` equivalent).

## Commands

Nothing native builds until `zuxml` and `zukomp` are installed **from the PR branches** — the released versions have no `inst/lib/*.a`, and `./configure` stops with a message saying so:

```sh
Rscript -e 'pak::pak(c("pedrobtz/zuxml@feat/expose-expat-for-linkingto",
                       "pedrobtz/zukomp@feat/expose-miniz-zip-for-linkingto"))'
```

```sh
Rscript -e 'devtools::document()'      # roxygen -> NAMESPACE + man/
Rscript -e 'devtools::load_all()'      # compile + load for interactive work
Rscript -e 'devtools::test()'
Rscript -e 'devtools::test(filter = "linking")'               # tests/testthat/test-linking.R
Rscript -e 'devtools::check()'         # target 0 errors / 0 warnings / 0 notes
```

To check the link itself rather than trust it — which archive was used, and whether anything was left undefined:

```sh
Rscript -e 'zuxlsx::zuxlsx_native()'   # versions actually linked in
./configure && grep PKG_LIBS src/Makevars
nm -gu src/zuxlsx.so | grep -E 'XML_|mz_zip'   # must print nothing
```

Offline, `check()` emits a spurious `checking for future file timestamps ... NOTE`. Suppress it to see the real result:

```sh
Rscript -e 'devtools::check(env_vars = c("_R_CHECK_SYSTEM_CLOCK_" = "0"))'
```

CI is [R-CMD-check.yaml](.github/workflows/R-CMD-check.yaml) (macOS/Windows/Ubuntu × devel/release/oldrel-1) and [pkgdown.yaml](.github/workflows/pkgdown.yaml).

## Conventions inherited from the `zu*` siblings

These are established in `zukomp` and `zuxml` (see `~/src/github.com/pedrobtz/zukomp/CLAUDE.md`) and should hold here unless the design doc says otherwise.

- **Naming by layer.** R exports get a short package-specific prefix (`komp_`, `zux_`); the C ABI gets `zu_`-family names; entry points and registration get the package name (`R_init_zuxlsx`, `zuxlsx_get_api`); internal-only symbols are never installed. Nothing that reads as another library's ABI (`unz*`, `mz_zip_*`, Expat's `XML_*`) may be re-exported.
- **`src/Makevars` is portable make only**, with `OBJECTS` listed explicitly — no GNU-make conditionals or `$(wildcard)` (that would force `SystemRequirements: GNU make`), and no `-W*`/optimisation overrides (CRAN policy).
- **No `Rf_error()` below the outermost `.Call`.** C layers return a status enum; `Rf_error()` and `R_CheckUserInterrupt()` both longjmp past any `free()`. Heap state that must survive such a jump belongs to an external pointer with `R_RegisterCFinalizerEx(..., TRUE)`, or to `R_alloc` under `vmaxget`/`vmaxset`. This matters more here than in `zukomp`: an XLSX read holds a ZIP handle, a parser and column builders live at once.
- **Tests assert on condition classes, never message text** (`expect_error(..., class = "zuxlsx_zip_error")`); wording is covered by snapshots. Tests are self-sufficient (inputs built inside each `test_that()`), self-contained (`withr::local_*()`), and must pass under `devtools::test(shuffle = TRUE)`.
- **Fixtures are committed, never generated at test time**, with provenance in a `MANIFEST.tsv` and a `tools/` generator that supports `--check` for reproducibility. CRAN guarantees no Python and no external tooling. Design §17.4 specifies the `valid/` `unusual/` `invalid/` corpus layout.
- **Vendored third-party code under `src/vendor/` is never edited in place** — patches live in `tools/patches/`, provenance in `tools/vendor/manifest.tsv`, per-file checksums in `tools/vendor/checksums.sha256`. Re-derive the vendored xlsxio by unpacking pristine 0.2.36 and applying `tools/patches/xlsxio/*.patch` in order; never hand-edit `src/vendor/xlsxio/`. There is no `tools/vendor/fetch|record|verify` script yet (zukomp has them and is the model).

## Licensing

xlsxio is MIT and its notices are preserved in [src/vendor/xlsxio/LICENSE.txt](src/vendor/xlsxio/LICENSE.txt) and [inst/COPYRIGHTS](inst/COPYRIGHTS) (design §20). Still outstanding: `DESCRIPTION` needs a real `Authors@R` — the maintainer is still `First Last` — plus a `cph` entry for Brecht Sanders (xlsxio), and the same for Expat/miniz copyright holders if option 1 above is taken.
