#!/bin/sh
# The R-free C stays R-free: cfb.c, encinfo.c, agile.c and utf8file.c, and
# their headers, include no R header and call no R API. That is what lets
# tools/fuzz compile them without R (#45), and it is easy to lose by adding
# one convenient Rf_ call.
set -eu
cd "$(dirname -- "$0")/.."
status=0
for f in src/cfb.c src/cfb.h src/encinfo.c src/encinfo.h \
         src/agile.c src/agile.h src/utf8file.c src/utf8file.h; do
    if grep -nE '#include *[<"](R|Rinternals|Rdefines|R_ext/[^>"]*)\.h[>"]|\bRf_|\bSEXP\b|\bPROTECT\(' "$f"; then
        printf 'FAIL %s reaches into R\n' "$f" >&2
        status=1
    fi
done
[ "$status" -eq 0 ] && printf 'ok  the R-free sources include no R\n'
exit "$status"
