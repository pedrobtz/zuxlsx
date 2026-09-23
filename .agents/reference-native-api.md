# Native API Reference: xlsxio, Expat, miniz ZIP

Copied and trimmed from `libs.md` in the `utopp/pkg-xlsx` prototype
(`/Users/pbtz/Documents/repos/gh/utopp/pkg-xlsx`), which vendors the same
xlsxio 0.2.36 reader on top of bundled Expat and miniz and has it working
end to end. Sections for `libxls` (.xls) and `cxlsb` (.xlsb), and the xlsxio
writer API, are dropped: both formats and workbook writing are out of scope
per design §21.

Read this as a map of the C surface the vendored reader in `src/vendor/xlsxio/`
depends on. What `zuxlsx` may call was settled on 2026-09-18, when both sibling
packages were widened to install the archives and the headers: `src/zuxlsx.c`
calls the xlsxio reader, and Expat and miniz are linked but reached only
through it, except in three places: on the failure path where a workbook that
declared no worksheet is reopened with miniz and re-parsed with Expat directly
to say *which* part is broken, or checked for `xl/workbook.bin` to recognise
an `.xlsb`; and `zuxlsx_native()`, which calls `XML_ExpatVersion()`. See
"Where the design doc and reality disagreed" in CLAUDE.md for the history.

**Three accessors below are not upstream's.** `xlsxioread_sheet_last_cell_type()`
and `xlsxioread_sheet_last_cell_is_date()` come from
`0003-expose-cell-type-and-number-format.patch`, and
`xlsxioread_sheet_date1904()` from `0004-expose-workbook-date-epoch.patch`.
Without them xlsxio hands back text and nothing else, and neither type
inference nor dates would be possible. They are listed here because
`tools/fuzz/harness.c` and `src/zuxlsx.c` both call them.

## xlsxio

xlsxio is the package-facing native XLSX layer. It hides most ZIP and XML
details behind reader and writer handles.

### Reader API

The main reader type is `xlsxioreader`.

Common lifecycle:

1. Open an XLSX source with `xlsxioread_open()`, `xlsxioread_open_filehandle()`,
   or `xlsxioread_open_memory()`.
2. List or select worksheets with `xlsxioread_list_sheets()` or the sheet-list
   iterator API.
3. Read sheet data with either callback processing or row/cell iteration.
4. Release resources with `xlsxioread_close()`.

Main functions:

| Function or group | Use |
| --- | --- |
| `xlsxioread_get_version()`, `xlsxioread_get_version_string()` | Inspect the vendored xlsxio version. |
| `xlsxioread_open()` | Open an `.xlsx` file by path. |
| `xlsxioread_open_filehandle()` | Open from an existing binary file descriptor. |
| `xlsxioread_open_memory()` | Open from an in-memory XLSX buffer. |
| `xlsxioread_close()` | Free the reader and close archive resources. |
| `xlsxioread_list_sheets()` | Visit each worksheet name via callback. |
| `xlsxioread_sheetlist_open()`, `xlsxioread_sheetlist_next()`, `xlsxioread_sheetlist_close()` | Iterate worksheet names without providing a callback. |
| `xlsxioread_process()` | Process a worksheet via cell and row callbacks. This is the main read path used by `src/bindings.c`. |
| `xlsxioread_sheet_open()`, `xlsxioread_sheet_next_row()`, `xlsxioread_sheet_next_cell()`, `xlsxioread_sheet_close()` | Pull-style row/cell iteration. |
| `xlsxioread_sheet_next_cell_string()`, `xlsxioread_sheet_next_cell_int()`, `xlsxioread_sheet_next_cell_float()`, `xlsxioread_sheet_next_cell_datetime()` | Pull the next cell converted to a specific C type. |
| `xlsxioread_sheet_last_row_index()`, `xlsxioread_sheet_last_column_index()`, `xlsxioread_sheet_flags()` | Inspect the iterator's current position and flags. |
| `xlsxioread_free()` | Free strings allocated by xlsxio, such as values returned by `xlsxioread_sheet_next_cell()`. |

Important reader flags:

| Flag | Meaning |
| --- | --- |
| `XLSXIOREAD_SKIP_NONE` | Preserve all rows and cells that xlsxio reports. |
| `XLSXIOREAD_SKIP_EMPTY_ROWS` | Skip empty rows. |
| `XLSXIOREAD_SKIP_EMPTY_CELLS` | Skip empty cells. |
| `XLSXIOREAD_SKIP_ALL_EMPTY` | Skip both empty rows and empty cells. |
| `XLSXIOREAD_SKIP_EXTRA_CELLS` | Skip cells to the right of the header width. |
| `XLSXIOREAD_SKIP_HIDDEN_ROWS` | Skip rows marked hidden in the worksheet XML. |

Callback types:

| Type | Use |
| --- | --- |
| `xlsxioread_list_sheets_callback_fn` | Receives each sheet name. |
| `xlsxioread_process_cell_callback_fn` | Receives row number, column number, and cell value. |
| `xlsxioread_process_row_callback_fn` | Receives end-of-row events with the row number and maximum column. |

## Expat

Expat is a streaming, callback-based XML parser. In this package it is used
inside `src/vendor/xlsxio/lib/xlsxio_read.c` to parse XLSX XML parts as they are
read from the ZIP archive.

The main parser type is `XML_Parser`.

Common lifecycle:

1. Create a parser with `XML_ParserCreate()`, `XML_ParserCreateNS()`, or
   `XML_ParserCreate_MM()`.
2. Attach application state with `XML_SetUserData()`.
3. Register handlers with setter functions such as `XML_SetElementHandler()`
   and `XML_SetCharacterDataHandler()`.
4. Feed XML with `XML_Parse()` or the buffer API `XML_GetBuffer()` plus
   `XML_ParseBuffer()`.
5. Inspect parse status and errors if needed.
6. Free the parser with `XML_ParserFree()`.

Main functions:

| Function or group | Use |
| --- | --- |
| `XML_ParserCreate()` | Create a parser for an optional encoding. |
| `XML_ParserCreateNS()` | Create a parser with namespace processing. |
| `XML_ParserCreate_MM()` | Create a parser with custom memory functions. |
| `XML_ParserReset()` | Reuse a parser for another document. |
| `XML_SetUserData()`, `XML_GetUserData()` | Store and retrieve callback state. |
| `XML_SetElementHandler()`, `XML_SetStartElementHandler()`, `XML_SetEndElementHandler()` | Register element start/end callbacks. |
| `XML_SetCharacterDataHandler()` | Register text-content callbacks. The buffer is not null-terminated; use the supplied length. |
| `XML_SetCommentHandler()`, `XML_SetCdataSectionHandler()`, `XML_SetProcessingInstructionHandler()` | Register less common XML event callbacks. |
| `XML_SetNamespaceDeclHandler()` | Register namespace declaration callbacks. |
| `XML_SetDefaultHandler()`, `XML_SetDefaultHandlerExpand()` | Receive otherwise unhandled XML data. |
| `XML_SetDoctypeDeclHandler()`, `XML_SetEntityDeclHandler()`, `XML_SetExternalEntityRefHandler()` | Handle DTD and entity-related events. |
| `XML_Parse()` | Parse a caller-owned byte buffer. |
| `XML_GetBuffer()`, `XML_ParseBuffer()` | Let Expat provide a parse buffer, then parse the bytes placed in it. xlsxio uses this path while streaming ZIP entries. |
| `XML_StopParser()`, `XML_ResumeParser()` | Suspend or resume parsing. xlsxio uses this to implement row/cell and sheet-name iterators. |
| `XML_GetParsingStatus()` | Inspect whether a parser is initialized, parsing, finished, or suspended. |
| `XML_GetErrorCode()`, `XML_ErrorString()` | Convert parse failures into diagnostic information. |
| `XML_GetCurrentLineNumber()`, `XML_GetCurrentColumnNumber()`, `XML_GetCurrentByteIndex()`, `XML_GetCurrentByteCount()` | Locate parser position for diagnostics. |
| `XML_MemMalloc()`, `XML_MemRealloc()`, `XML_MemFree()` | Allocate with the parser's memory hooks. |
| `XML_ParserFree()` | Free parser resources. |
| `XML_ExpatVersion()`, `XML_ExpatVersionInfo()`, `XML_GetFeatureList()` | Inspect Expat version and compiled features. |
| `XML_SetBillionLaughsAttackProtectionMaximumAmplification()`, `XML_SetBillionLaughsAttackProtectionActivationThreshold()` | Configure entity expansion protection. |
| `XML_SetReparseDeferralEnabled()` | Configure reparse deferral behavior. |

Common handler types:

| Type | Callback receives |
| --- | --- |
| `XML_StartElementHandler` | User data, element name, and a null-terminated attribute name/value array. |
| `XML_EndElementHandler` | User data and element name. |
| `XML_CharacterDataHandler` | User data, character buffer, and buffer length. |
| `XML_CommentHandler` | User data and comment text. |
| `XML_StartNamespaceDeclHandler`, `XML_EndNamespaceDeclHandler` | Namespace prefix and URI events. |
| `XML_ExternalEntityRefHandler` | External entity references. |

Package-specific notes:

| Detail | Meaning |
| --- | --- |
| `XML_STATIC` | The build uses Expat as bundled static source, not a shared system library. |
| `EXPAT_R_NO_STDERR` | The package-local config avoids Expat writing diagnostics directly to stderr. |
| `expat_config.h` | Package-local configuration header for building the vendored Expat sources. |
| Namespace handling | xlsxio's XML matching uses suffix-insensitive helpers so nonstandard namespace prefixes can still be read. |

## miniz

miniz provides ZIP archive read/write APIs plus zlib-like compression helpers.
In this package it replaces the previous system ZIP backends.

The main ZIP type is `mz_zip_archive`.

### ZIP Reader API

Common lifecycle:

1. Zero or allocate an `mz_zip_archive`.
2. Open an archive with one of the reader init functions.
3. Locate, inspect, and extract entries.
4. End the reader with `mz_zip_reader_end()` or `mz_zip_end()`.

Main functions:

| Function or group | Use |
| --- | --- |
| `mz_zip_zero_struct()` | Initialize an archive struct to a clean zero state. |
| `mz_zip_reader_init()` | Initialize a reader around custom archive I/O callbacks and size. |
| `mz_zip_reader_init_file()`, `mz_zip_reader_init_file_v2()` | Open a ZIP archive from a filename. |
| `mz_zip_reader_init_mem()` | Open a ZIP archive from memory. |
| `mz_zip_reader_init_cfile()` | Open from an existing C file handle. |
| `mz_zip_reader_get_num_files()` | Count central-directory entries. |
| `mz_zip_reader_get_filename()` | Read an entry name by index. |
| `mz_zip_reader_locate_file()`, `mz_zip_reader_locate_file_v2()` | Find an entry by archive path. Since patch 0005 the vendored xlsxio calls neither: `zu_locate_member()` scans the central directory with `mz_zip_reader_get_num_files()`/`mz_zip_reader_get_filename()`, folds case and backslashes, and takes the first match, because `_v2()` resolves a duplicated name differently depending on `MZ_ZIP_FLAG_CASE_SENSITIVE`. `src/zuxlsx.c` still uses `_v2()` with flags `0` in its failure-path helpers (`file_is_xlsb()`, `first_malformed_part()`). |
| `mz_zip_reader_file_stat()` | Fill an `mz_zip_archive_file_stat` with metadata for an entry. |
| `mz_zip_reader_is_file_a_directory()`, `mz_zip_reader_is_file_encrypted()`, `mz_zip_reader_is_file_supported()` | Inspect entry capabilities before extraction. |
| `mz_zip_reader_extract_iter_new()`, `mz_zip_reader_extract_iter_read()`, `mz_zip_reader_extract_iter_free()` | Stream an entry out in chunks. xlsxio uses this path for XML parsing. |
| `mz_zip_reader_extract_to_mem()`, `mz_zip_reader_extract_to_heap()` | Extract an entry into caller-provided memory or miniz-allocated heap memory. |
| `mz_zip_reader_extract_to_callback()` | Extract an entry through a write callback. |
| `mz_zip_reader_extract_to_file()`, `mz_zip_reader_extract_to_cfile()` | Extract an entry to a filesystem path or C file handle. |
| `mz_zip_validate_file()`, `mz_zip_validate_archive()` | Validate ZIP entry or archive integrity. |
| `mz_zip_reader_end()` | End reading and free archive resources. |

### Error And Metadata API

| Function or group | Use |
| --- | --- |
| `mz_zip_get_mode()`, `mz_zip_get_type()` | Inspect archive state and backing type. |
| `mz_zip_get_archive_size()`, `mz_zip_get_archive_file_start_offset()` | Inspect archive layout. |
| `mz_zip_get_last_error()`, `mz_zip_set_last_error()`, `mz_zip_clear_last_error()` | Manage the archive's last error code. |
| `mz_zip_get_error_string()` | Convert a `mz_zip_error` code to text. |
| `mz_zip_is_zip64()` | Check whether the archive uses ZIP64 structures. |
| `mz_zip_end()` | Universal end function for either reader or writer mode. |

