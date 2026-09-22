# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`zuxlsx` is an R package for **reading `.xlsx` workbooks** with no system XML or ZIP dependency, built on the sibling `zu*` packages: `zuxml` (Expat-backed XML) and `zukomp` (miniz-backed DEFLATE), with vendored `xlsxio` supplying the OOXML logic.

## Current state: it builds and reads workbooks

The native stack compiles, links and runs: `xlsx_sheets()` opens a real `.xlsx` and lists its worksheets, which means miniz (from `zukomp`) opened the ZIP, Expat (from `zuxml`) parsed `xl/workbook.xml`, and vendored xlsxio drove both. 41 tests pass, shuffled, and `R CMD check --as-cran` is 0 errors / 0 warnings / 1 note (the note is "New submission" plus the two non-CRAN `LinkingTo` packages).

**This is a build slice, not the reading API.** `read_xlsx()`, the cell event model and the column builders (design §12–§14) are unstarted. The two exported functions exist so that a broken native build is a failing test rather than something discovered later:

- `xlsx_sheets(path)` — exercises both archives on a real file.
- `zuxlsx_native()` — reports `xlsxio` 0.2.36, `expat_2.8.4`, miniz `11.3.2`. It calls `XML_ExpatVersion()` rather than reading a macro, so a header on the include path without the archive behind it fails at link time.

The build:

- [configure](configure) / [configure.win](configure.win) resolve `system.file("lib", package = ...)` for `zuxml` and `zukomp` and substitute them into [src/Makevars.in](src/Makevars.in). `LinkingTo` puts the *headers* on the path by itself (`CLINK_CPPFLAGS`); there is no equivalent for a library, and the alternatives are worse — `$(shell …)` would force `SystemRequirements: GNU make`, and an `Imports:` entry would add a runtime dependency that nothing needs, since the archives are linked statically.
- `DESCRIPTION` has `LinkingTo: zukomp, zuxml` and **no `Imports:`**, which is what design §3 asks for.
- **`Remotes:` tracks `pedrobtz/zuxml@main` and `pedrobtz/zukomp@main`**, since neither is on CRAN. `@main` is deliberate and is not a version pin: the three packages are developed together, so zuxlsx builds against what the siblings actually are, and a sibling release that breaks this package is a bug to fix in the sibling rather than a version to freeze away from. That has real cost — a zukomp release broke Windows here on 2026-09-19 — and it is the cost being chosen. Do not pin a *feature* branch: those are deleted on merge and the ref then 404s. Drop `Remotes:` entirely before any CRAN submission -- on submission day, not before, since it is what makes a GitHub install work. The full sequence, including why the siblings must reach CRAN first, is in [.agents/release-checklist.md](.agents/release-checklist.md).
- `src/Makevars` is generated and `.gitignore`d. `cleanup` removes it.

Vendored and copied from the working `utopp/pkg-xlsx` prototype at `/Users/pbtz/Documents/repos/gh/utopp/pkg-xlsx`:

- [src/vendor/xlsxio/](src/vendor/xlsxio/) — xlsxio 0.2.36, **reader only** (`xlsxio_read.c`, `xlsxio_read_sharedstrings.c`, headers, `LICENSE.txt`). The writer is not bundled; writing is out of scope (§21). Upstream CRLF line endings are kept deliberately.
- [tools/patches/xlsxio/](tools/patches/xlsxio/) — two patches, applied in order. `0001-miniz-zip-backend.patch` is **design §5's "main adaptation cost", already solved**: it adds a `USE_MINIZ` backend beside xlsxio's minizip/minizip-ng/libzip ones, mapping `unzOpen`/`unzLocateFile`/`unzReadCurrentFile` onto `mz_zip_reader_init_file` / `_locate_file_v2` / `_extract_iter_read`. `0002-namespace-insensitive-relationship-id.patch` looks a worksheet's relationship id up as `id` rather than `r:id`, so a workbook binding the relationships namespace to another prefix still resolves. The pair reproduces the committed copy byte for byte from the pristine 0.2.36 tarball. Provenance is in [tools/vendor/manifest.tsv](tools/vendor/manifest.tsv), [tools/vendor/checksums.sha256](tools/vendor/checksums.sha256) and [inst/COPYRIGHTS](inst/COPYRIGHTS); **`tools/vendor/verify` checks all of it offline and is the thing to run after touching anything under `src/vendor/`.**
- [tests/testthat/sheets/](tests/testthat/sheets/) — seven readxl interoperability workbooks (inline strings, missing parts, nonstandard namespace prefix, UTF-8 sheet names, blanks), MIT, with provenance and checksums in `MANIFEST.tsv` there, all verified byte for byte against readxl at commit `47f8aeac`. The generated §17.4 corpus is still to be built.
- [.agents/reference-native-api.md](.agents/reference-native-api.md) — function map of the xlsxio reader, Expat and miniz ZIP APIs the vendored code uses.

The prototype also holds a `USE_MINIZ` patch for `xlsxio_write.c`, a working `src/bindings.c` + `R/xlsxio.R` read/write path, and research notes (`ROADMAP.md`, `calamine.md`, `libs.md`). None of that was copied; go back for it if writing or a quick end-to-end spike is wanted.

Everything else described below is unstarted.

## The design doc is the spec

[.agents/design-zuxlsx.md](.agents/design-zuxlsx.md) is binding, not background — §1–§23 cover the dependency model, the miniz ZIP backend adaptation, the streaming pipeline, the cell/column abstractions, the error classes, and the test corpus layout. Read the relevant section before writing code. If implementation shows the design is wrong, **change the design doc in the same commit** rather than diverging silently.

## Where the design doc and reality disagreed (resolved 2026-09-18)

The doc was written before `zuxml` and `zukomp` reached v1, and three of its assumptions did not hold against the packages as shipped at v1. **Both sibling PRs merged on 2026-09-18 and this is now settled**; the history is kept because it explains why two v1 packages were widened, and because a future reader hitting a link error will want it.

- **§3/§7 "`LinkingTo` only, no `R_GetCCallable()`" is not how those packages work.** `zuxml/inst/include/zuxml.h` and `zukomp/inst/include/zukomp-r.h` document the opposite contract: `Imports:` + `LinkingTo:`, resolving a versioned function table at runtime (`zuxml_api_get()` → `R_GetCCallable("zuxml", "zuxml_api_v2")`; `zukomp_api()` → `zukomp_get_api`). That is the supported path.
- **§4 `inst/lib/libzuxml.a` / `libzukomp.a` did not exist at v1**, and neither package installed `expat.h` or `miniz.h`; `inst/include/` held only `zuxml.h`, `zukomp.h`, `zukomp-r.h`. So xlsxio could not be handed the raw Expat API as §4 assumes. **Both archives and both vendored headers are installed today** — see *What the siblings install now* below.
- **§5 assumes miniz's ZIP reader is available through `zukomp`. At v1 it was not.** `zukomp/src/Makevars` compiles miniz with `-DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_STDIO`, and zukomp's own `test-abi.R` asserts no `mz_zip_*` symbol is exported. zukomp gives raw DEFLATE/zlib/gzip over memory buffers only — no central directory, no local headers, no entry lookup.

Both are now installable straight from GitHub `main`; see **Commands** below.

**The vendored xlsxio makes this concrete.** It `#include`s `<expat.h>` and calls `XML_ParserCreate`/`XML_GetBuffer`/`XML_ParseBuffer`/`XML_StopParser` directly, and under `USE_MINIZ` it calls `mz_zip_*` directly. Neither symbol set was reachable through `LinkingTo: zuxml, zukomp` at v1, which is what the two sibling PRs below changed.

**Decided (2026-09-17): widen the siblings to match the design, rather than changing the design. Both merged 2026-09-18.**

- **pedrobtz/zuxml#7** — installs `expat.h`/`expat_external.h` and ships `inst/lib/libzuxml.a` (the Expat objects, no R glue). `XML_StopParser`/`XML_ResumeParser` are in it, which is what xlsxio's row/cell and sheet-list iterators need.
- **pedrobtz/zukomp#10** — ships `inst/lib/libzukomp.a` with miniz's ZIP reader, plus `miniz.h`. It compiles `miniz.c` a *second* time rather than widening the trim, so `zukomp.so` still exports no `mz_zip_*` symbol and `test-abi.R` needed no relaxing. `MINIZ_NO_TIME` also had to go for the archive build, or `mz_zip_archive_file_stat.m_time` is miniz's `m_padding`.

Proven end to end before the PRs were opened: `src/vendor/xlsxio/` compiles against those installed headers, links both archives, and reads the fixtures in [tests/testthat/sheets/](tests/testthat/sheets/) — inline strings, UTF-8 sheet names, and a workbook with no `sharedStrings.xml` part.

`configure` resolves `system.file("lib", package = ...)` into `Makevars.in`, which keeps this `LinkingTo`-only, with no `Imports:` and no GNU make. Required defines: `-DXML_STATIC` (Windows) and `-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES` (everywhere — miniz would otherwise `#define` `compress`/`crc32`/`adler32` over any translation unit that also sees R's headers). **Both archive paths in `PKG_LIBS` are single-quoted**; unquoted, any library path containing a space (the norm on Windows) reaches the linker as two nonexistent arguments.

Rejected alternatives, for the record: vendoring Expat and miniz here as well (compiles today, but duplicates the siblings and contradicts §3/§6), and retargeting xlsxio onto the `zux_parser_*` wrapper API (blocked on `zuxml` having no `XML_StopParser` equivalent).

## What the siblings install now

Current as of 2026-09-22, and the contract this package is built on. An installed `zuxml` carries:

```
zuxml/include/expat.h          zuxml/include/zuxml.h
zuxml/include/expat_external.h zuxml/lib/libzuxml.a
```

`LinkingTo: zuxml` puts that `include` directory on the compiler's path, and `libzuxml.a` holds the Expat objects only — no R glue, so nothing collides inside `zuxlsx.so`. `zukomp` is the same shape for miniz (`include/miniz.h`, `lib/libzukomp.a`). Neither header exists under the siblings' `inst/include/` in *source* form: zuxml copies them out of its vendored tree during `src/install.libs.R`, so the header always matches the objects in the archive. Looking at a sibling's git tree and concluding the header is missing is the mistake to avoid.

The feature policy comes with it. zuxml compiles Expat with `XML_GE 0` and never defines `XML_DTD`, so entity references beyond the five built-ins are parse errors here too, and defining `XML_GE=1` in this package's `PKG_CPPFLAGS` would declare billion-laughs limiters that `libzuxml.a` does not define. zuxml's `vignette("linking")` and its `CLAUDE.md` are the reference; `zuxml/tools/zuxmltest/` is a minimal package in exactly this shape.

**Do not test for a version.** zuxml 0.1.0 exists both with and without the archive, so `./configure` checks for the file on disk, and any message about it should say that rather than naming a version.

## Commands

Nothing native builds until `zuxml` and `zukomp` are installed **from GitHub** — an older installed copy may predate the archives, and `./configure` stops with a message when it cannot find one. Version numbers do not settle it (zuxml 0.1.0 exists both ways); the file on disk does. `@main` is fine and is what `DESCRIPTION` asks for; a *feature* branch suffix is not, since those are deleted on merge.

```sh
Rscript -e 'pak::pak(c("pedrobtz/zuxml", "pedrobtz/zukomp"))'
```

```sh
Rscript -e 'devtools::document()'      # roxygen -> NAMESPACE + man/
Rscript -e 'devtools::load_all()'      # compile + load for interactive work
Rscript -e 'devtools::test()'
Rscript -e 'devtools::test(filter = "linking")'               # tests/testthat/test-linking.R
Rscript -e 'devtools::check()'         # target 0 errors / 0 warnings / 0 notes
```

To check the link itself rather than trust it — which archive was used, and whether anything was left undefined:

`configure` refuses to run without `R_HOME` (it needs it to find the *same* R whose library holds the two archives), so pass it explicitly when running the script by hand rather than through `R CMD INSTALL`. That regenerates `src/Makevars`, so this is a build input being rewritten, not a read-only check; `./cleanup` removes it.

```sh
Rscript -e 'zuxlsx::zuxlsx_native()'   # versions actually linked in
R_HOME="$(Rscript -e 'cat(R.home())')" ./configure && grep PKG_LIBS src/Makevars
nm -gu src/zuxlsx.so | grep -E 'XML_|mz_zip'   # must print nothing
./tools/vendor/verify                  # vendored tree + fixtures vs their manifests
```

Offline, `check()` emits a spurious `checking for future file timestamps ... NOTE`. Suppress it to see the real result:

```sh
Rscript -e 'devtools::check(env_vars = c("_R_CHECK_SYSTEM_CLOCK_" = "0"))'
```

Benchmarks against readxl and openxlsx2 are in [tools/bench/](tools/bench/), maintainer-only and `.Rbuildignore`d like `tools/corpus` and `tools/fuzz`. The workbooks are large (100 MB+) and of unestablished provenance, so they are cached outside the repository and are never fixtures:

```sh
./tools/bench/fetch-workbooks xlsx100mb        # -> ${ZUXLSX_BENCH_DIR:-~/.cache/zuxlsx-bench}
Rscript tools/bench/bench-read.R               # xlsx100mb, sheet 1
Rscript tools/bench/bench-read.R xlsx100mb 4   # workbook (id or path), sheet (index or name)
```

It times two things over `bench::mark()`: listing the worksheets, and reading one sheet. Listing is where the streaming design shows up — on a 105 MB workbook zuxlsx is ~2.5 ms against readxl's 1.6 s and openxlsx2's 19 s, because it is the only one of the three that stops after `xl/workbook.xml`. Reading is ~15% faster than readxl at a quarter of its R-level allocation. It does not check the three against each other; [tools/corpus/sweep.R](tools/corpus/sweep.R) is what compares values.

CI is [R-CMD-check.yaml](.github/workflows/R-CMD-check.yaml) (macOS/Windows/Ubuntu × devel/release/oldrel-1) and [pkgdown.yaml](.github/workflows/pkgdown.yaml).

## Conventions inherited from the `zu*` siblings

These are established in `zukomp` and `zuxml` (see `~/src/github.com/pedrobtz/zukomp/CLAUDE.md`) and should hold here unless the design doc says otherwise.

- **Naming by layer.** R exports get a short package-specific prefix (`komp_`, `zux_`); the C ABI gets `zu_`-family names; entry points and registration get the package name (`R_init_zuxlsx`, `zuxlsx_get_api`); internal-only symbols are never installed. Nothing that reads as another library's ABI (`unz*`, `mz_zip_*`, Expat's `XML_*`) may be re-exported.
- **`src/Makevars` is portable make only**, with `OBJECTS` listed explicitly — no GNU-make conditionals or `$(wildcard)` (that would force `SystemRequirements: GNU make`), and no `-W*`/optimisation overrides (CRAN policy).
- **No `Rf_error()` below the outermost `.Call`.** C layers return a status enum; `Rf_error()` and `R_CheckUserInterrupt()` both longjmp past any `free()`. Heap state that must survive such a jump belongs to an external pointer with `R_RegisterCFinalizerEx(..., TRUE)`, or to `R_alloc` under `vmaxget`/`vmaxset`. This matters more here than in `zukomp`: an XLSX read holds a ZIP handle, a parser and column builders live at once.
- **Tests assert on condition classes, never message text** (`expect_error(..., class = "zuxlsx_zip_error")`); wording is covered by snapshots. Tests are self-sufficient (inputs built inside each `test_that()`), self-contained (`withr::local_*()`), and must pass under `devtools::test(shuffle = TRUE)`.
- **Fixtures are committed, never generated at test time**, with provenance in a `MANIFEST.tsv` and a `tools/` generator that supports `--check` for reproducibility. CRAN guarantees no Python and no external tooling. Design §17.4 specifies the `valid/` `unusual/` `invalid/` corpus layout.
- **Vendored third-party code under `src/vendor/` is never edited in place** — patches live in `tools/patches/`, provenance in `tools/vendor/manifest.tsv`, per-file checksums in `tools/vendor/checksums.sha256`. `tools/vendor/fetch` re-derives the tree from the upstream tarball, `record` rewrites the checksums, and **`verify` checks offline that the committed tree, both manifests, `src/Makevars.in`'s defines and `inst/COPYRIGHTS` all agree** — run it after touching anything under `src/vendor/`, `tools/patches/` or the fixtures. It exists precisely because a hand edit to `xlsxio_read.c` once shipped undocumented while three files claimed the patch set reproduced the tree byte for byte.

## Licensing

xlsxio is MIT and its notices are preserved in [src/vendor/xlsxio/LICENSE.txt](src/vendor/xlsxio/LICENSE.txt) and [inst/COPYRIGHTS](inst/COPYRIGHTS) (design §20). `DESCRIPTION` carries Pedro Baltazar as `aut`/`cre`/`cph` and Brecht Sanders as `cph` for xlsxio. Expat and miniz are *linked*, not vendored here, so their notices stay with `zuxml` and `zukomp`; design §20 asks for that to be reviewed again before a CRAN submission, since static linking still redistributes them.
