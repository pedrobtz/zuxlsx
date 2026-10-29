/* libFuzzer target for the hand-written OLE2 path: the CFB reader
 * (src/cfb.c) and the EncryptionInfo parser (src/encinfo.c), on arbitrary
 * bytes -- which is what a password-protected workbook is until both have
 * accepted it. Design section 18, #45.
 *
 * Both files are plain C with no R, so they compile here as they are. Expat
 * comes from zuxml's vendored sources, as libzuxml.a is built from them.
 * agile.c is not here: it needs zucrypt's backend, and it only runs on what
 * these two have already accepted.
 *
 * Built by .github/workflows/fuzz.yaml through r-actions' fuzz.yml. With
 * -DZUXLSX_FUZZ_STANDALONE it also builds a main() that reads each file
 * named on the command line once, for running the seeds under ASan on a
 * machine without libFuzzer. */
#include "../../src/cfb.h"
#include "../../src/encinfo.h"

#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static const char *const NAMES[] = {
    "EncryptionInfo", "EncryptedPackage", "Workbook", "Book"
  };
  cfb c;
  size_t i;

  if (cfb_open(&c, data, size) != CFB_OK) return 0;
  for (i = 0; i < sizeof(NAMES) / sizeof(NAMES[0]); i++) {
    uint8_t *stream = NULL;
    size_t len = 0;
    cfb_has_stream(&c, NAMES[i]);
    if (cfb_stream(&c, NAMES[i], &stream, &len) != CFB_OK) continue;
    if (i == 0) {
      encinfo info;
      if (encinfo_parse(stream, len, &info) == ENCINFO_OK) encinfo_free(&info);
    }
    free(stream);
  }
  cfb_close(&c);
  return 0;
}

#ifdef ZUXLSX_FUZZ_STANDALONE
#include <stdio.h>

int main(int argc, char **argv) {
  int k;
  for (k = 1; k < argc; k++) {
    FILE *fp = fopen(argv[k], "rb");
    uint8_t *buf = NULL;
    long n;
    if (fp == NULL) return 1;
    fseek(fp, 0, SEEK_END);
    n = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    buf = malloc(n > 0 ? (size_t) n : 1);
    if (buf == NULL || fread(buf, 1, (size_t) n, fp) != (size_t) n) return 1;
    fclose(fp);
    LLVMFuzzerTestOneInput(buf, (size_t) n);
    free(buf);
  }
  return 0;
}
#endif
