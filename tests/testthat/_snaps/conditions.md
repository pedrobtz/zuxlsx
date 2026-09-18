# error messages are stable

    Code
      xlsx_sheets(1)
    Condition
      Error in `xlsx_sheets()`:
      ! `path` must be a single non-missing string.
    Code
      xlsx_sheets("no-such-file.xlsx")
    Condition
      Error in `xlsx_sheets()`:
      ! `path` does not exist: no-such-file.xlsx
    Code
      xlsx_sheets(not_xlsx)
    Condition
      Error in `xlsx_sheets()`:
      ! Cannot open '<tmp>/not-a-zip.xlsx' as an xlsx workbook.
      The file is not a readable ZIP archive. It may be truncated, corrupt, or not an xlsx file at all.
    Code
      xlsx_sheets(not_workbook)
    Condition
      Error in `xlsx_sheets()`:
      ! '<tmp>/not-a-workbook.xlsx' is a ZIP archive but not an xlsx workbook.
      It declares no worksheets.

