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

# every status's message is stable

    Code
      for (status in c(names(STATUS_CLASSES), "not_a_real_status")) {
        cat("-- ", status, "\n", message_of(status), "\n", sep = "")
      }
    Output
      -- zip_open
      Cannot open 'book.xlsx' as an xlsx workbook.
      The file is not a readable ZIP archive. It may be truncated, corrupt, or not an xlsx file at all.
      -- xml_malformed
      'book.xlsx' contains XML that is not well formed.
      The part 'xl/workbook.xml' could not be parsed (line 4).
      -- sheet_xml
      'book.xlsx' contains XML that is not well formed.
      The worksheet 'Sheet1' breaks off at line 7, so it could not be read in full.
      -- sheet_range
      'book.xlsx' is not a valid xlsx workbook.
      The worksheet 'Sheet1' refers to a cell beyond XFD1048576, the last cell a worksheet can have (line 7).
      -- sheet_shared_string
      'book.xlsx' is not a valid xlsx workbook.
      The worksheet 'Sheet1' refers to a shared string that does not exist (line 7).
      -- sheet_zip
      'book.xlsx' is damaged.
      The compressed data of worksheet 'Sheet1' does not match its recorded size or checksum.
      -- sheet_missing
      'book.xlsx' is not a valid xlsx workbook.
      No part holding the worksheet 'Sheet1' can be found through its relationships.
      -- format_encrypted
      'book.xlsx' is a password-protected workbook.
      Pass its password as `password = ` to read it.
      -- format_xls
      'book.xlsx' is a legacy .xls workbook, not an xlsx workbook.
      An .xls stores its worksheets as BIFF binary records rather than XML. zuxlsx reads xlsx only. Open it in Excel and save as .xlsx.
      -- format_ole2
      'book.xlsx' is an OLE2 file, not an xlsx workbook.
      Its directory names neither an encrypted package nor a BIFF workbook, so it is some other OLE2 document. zuxlsx reads xlsx only.
      -- format_xlsb
      'book.xlsx' is an xlsb workbook, not an xlsx workbook.
      An xlsb stores its worksheets as binary records rather than XML. zuxlsx reads xlsx only.
      -- agile_password
      The password for 'book.xlsx' is not correct.
      The workbook's password verifier did not match. If the password is right, the file's encryption header is damaged; the two cannot be told apart.
      -- agile_integrity
      'book.xlsx' failed its integrity check.
      The password is correct, but the encrypted package does not match the HMAC stored with it: the file was damaged or altered after it was encrypted. Nothing was decrypted.
      -- agile_malformed
      'book.xlsx' is a damaged encrypted workbook.
      Its encryption parameters or its encrypted package are inconsistent, so it cannot be decrypted with any password.
      -- agile_unsupported
      'book.xlsx' is encrypted with an algorithm zuxlsx does not implement.
      zuxlsx decrypts agile encryption with AES in CBC mode and SHA-1 or SHA-2, which is what Excel has written since 2013.
      -- agile_password_utf8
      `password` is not valid text in its declared encoding.
      -- agile_crypto
      The cryptographic backend failed while decrypting 'book.xlsx' (ZUC_ERR_BACKEND).
      -- cfb_not_cfb
      'book.xlsx' is not an OLE2 container.
      -- cfb_malformed
      'book.xlsx' is a damaged OLE2 container.
      Its sector tables or directory are inconsistent, so the streams in it cannot be read.
      -- cfb_not_encrypted
      'book.xlsx' is an OLE2 container, but not an encrypted workbook.
      It holds no EncryptionInfo and EncryptedPackage streams.
      -- encryption_standard
      'book.xlsx' uses standard encryption, which zuxlsx does not decrypt.
      That is Office 2007's scheme (AES-128, SHA-1). zuxlsx decrypts agile encryption, which Excel has written since 2013: open the file in Excel and save it again to convert it.
      -- encryption_extensible
      'book.xlsx' uses extensible encryption, from a third-party provider, which zuxlsx does not decrypt.
      -- encryption_unknown
      'book.xlsx' is encrypted with a scheme whose version zuxlsx does not recognise.
      -- encryption_certificate
      'book.xlsx' can only be opened with a certificate, not a password.
      zuxlsx decrypts password-protected workbooks only.
      -- sheet_not_found
      'book.xlsx' has no such worksheet.
      -- ooxml_no_sheets
      'book.xlsx' is a ZIP archive but not an xlsx workbook.
      It declares no worksheets.
      -- memory
      Ran out of memory while reading 'book.xlsx'.
      -- bad_path
      `path` must be a single non-missing string.
      -- not_a_real_status
      Internal error: unrecognised status 'not_a_real_status' from the native layer.

