#include "utf8file.h"

#ifdef _WIN32
#include <stdlib.h>
#include <wchar.h>
#include <windows.h>

FILE *zuxlsx_fopen_utf8(const char *path) {
  wchar_t *wide;
  FILE *fp = NULL;
  int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);

  if (n <= 0) return NULL;
  wide = (wchar_t *) malloc((size_t) n * sizeof *wide);
  if (wide == NULL) return NULL;
  if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, n) > 0) {
    fp = _wfopen(wide, L"rb");
  }
  free(wide);
  return fp;
}
#else
FILE *zuxlsx_fopen_utf8(const char *path) {
  return fopen(path, "rb");
}
#endif
