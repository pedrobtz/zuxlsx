# The native statuses and their conditions, for test-conditions.R. Here
# rather than at the top of that file because testthat shuffles test order,
# and a definition at the top of one file is not reliably in scope.

# Every status the native layer can return, with the class vector it must
# become. Most are reachable from a file; memory and agile_crypto are not
# (allocation failure and a backend fault), and the C-side sheet_not_found
# and bad_path are pre-empted by the R checks, so the mapping itself is what
# is tested here.
STATUS_CLASSES <- list(
  zip_open = "zuxlsx_zip_error",
  xml_malformed = "zuxlsx_xml_error",
  sheet_xml = "zuxlsx_xml_error",
  sheet_range = "zuxlsx_ooxml_error",
  sheet_shared_string = "zuxlsx_ooxml_error",
  sheet_zip = "zuxlsx_zip_error",
  part_zip = "zuxlsx_zip_error",
  format_encrypted = c("zuxlsx_encrypted_error", "zuxlsx_unsupported_format_error"),
  format_xls = "zuxlsx_unsupported_format_error",
  format_ole2 = "zuxlsx_unsupported_format_error",
  format_xlsb = "zuxlsx_unsupported_format_error",
  agile_password = c("zuxlsx_password_error", "zuxlsx_encrypted_error"),
  agile_integrity = "zuxlsx_integrity_error",
  agile_malformed = "zuxlsx_integrity_error",
  agile_unsupported = "zuxlsx_unsupported_format_error",
  agile_password_utf8 = "zuxlsx_input_error",
  agile_crypto = character(),
  cfb_not_cfb = "zuxlsx_input_error",
  cfb_malformed = "zuxlsx_integrity_error",
  cfb_not_encrypted = "zuxlsx_unsupported_format_error",
  encryption_standard = "zuxlsx_unsupported_format_error",
  encryption_extensible = "zuxlsx_unsupported_format_error",
  encryption_unknown = "zuxlsx_unsupported_format_error",
  encryption_certificate = "zuxlsx_unsupported_format_error",
  sheet_not_found = "zuxlsx_sheet_error",
  ooxml_no_sheets = "zuxlsx_ooxml_error",
  memory = "zuxlsx_memory_error",
  bad_path = "zuxlsx_input_error"
)

# The value each status carries, where it carries one.
status_value <- function(status) {
  switch(status,
    xml_malformed = list(part = "xl/workbook.xml", line = 4L),
    part_zip = list(part = "xl/sharedStrings.xml", line = 0L),
    sheet_xml = ,
    sheet_range = ,
    sheet_shared_string = ,
    sheet_zip = list(sheet = "Sheet1", line = 7L),
    agile_crypto = "ZUC_ERR_BACKEND",
    NULL
  )
}
