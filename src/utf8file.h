/* Opening a file named by a UTF-8 path, for reading.
 *
 * R hands the native layer paths in UTF-8 (Rf_translateCharUTF8). fopen()
 * takes them in the native encoding, which on Windows before R 4.2 is a code
 * page rather than UTF-8, so a non-ASCII path would not open there. miniz
 * already converts to UTF-16 and calls _wfopen for the archive itself; this
 * does the same for the two places that open the file directly.
 *
 * Kept out of zuxlsx.c because <windows.h> and R's headers do not mix. */
#ifndef ZUXLSX_UTF8FILE_H
#define ZUXLSX_UTF8FILE_H

#include <stdio.h>

FILE *zuxlsx_fopen_utf8(const char *path);

#endif
