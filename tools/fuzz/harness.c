/* A standalone reader, for running the native layer under a sanitiser.
 *
 *   tools/fuzz/build
 *   tools/fuzz/harness FILE...
 *
 * This exists because the package's own tests cannot find most memory bugs.
 * They run inside R, and a heap overflow that does not happen to land on
 * something fatal produces a passing test: R reports a value, the value looks
 * plausible, and nothing says the read walked off the end of a buffer. Only a
 * sanitiser sees that, and a sanitiser needs a build of R it does not have
 * here -- so the C is exercised directly instead, without R in the way.
 *
 * It drives the same calls zuxlsx does, including the accessors added by the
 * vendored patches, because a path this does not take is a path the sanitiser
 * does not check.
 *
 * Exit status is 0 whether or not a file reads: a corpus of deliberately
 * broken archives is the point, and refusing one is a correct outcome. What
 * matters is the sanitiser's own report, which it writes to stderr and which
 * makes the process exit non-zero by itself.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xlsxio_read.h>

static int sheet_count;

static int count_sheet(const XLSXIOCHAR *name, void *data) {
  (void)data;
  /* Touch the name: a sheet list that hands back a bad pointer should be
     caught here rather than in whatever the caller does with it later. */
  if (name != NULL) {
    sheet_count += (int)(strlen(name) > 0);
  }
  return 0;
}

static void read_one(const char *path) {
  xlsxioreader reader;
  xlsxioreadersheet sheet;
  char *value;
  unsigned long cells = 0;

  reader = xlsxioread_open(path);
  if (reader == NULL) {
    return;
  }

  sheet_count = 0;
  xlsxioread_list_sheets(reader, count_sheet, NULL);

  /* NULL asks for the first worksheet, which is the path a caller takes when
     it does not name one. */
  sheet = xlsxioread_sheet_open(reader, NULL, XLSXIOREAD_SKIP_NONE);
  if (sheet != NULL) {
    while (xlsxioread_sheet_next_row(sheet)) {
      while ((value = xlsxioread_sheet_next_cell(sheet)) != NULL) {
        /* Every accessor the patches added, on every cell. */
        (void)xlsxioread_sheet_last_cell_type(sheet);
        (void)xlsxioread_sheet_last_cell_is_date(sheet);
        if (value[0] != '\0') {
          cells++;
        }
        free(value);
      }
    }
    (void)xlsxioread_sheet_date1904(sheet);
    xlsxioread_sheet_close(sheet);
  }
  xlsxioread_close(reader);

  printf("%s\tsheets=%d\tcells=%lu\n", path, sheet_count, cells);
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; i++) {
    read_one(argv[i]);
  }
  return 0;
}
