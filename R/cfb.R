# Streams at the root of a CFB container (design section 21c, step 1).
#
# Internal: nothing exported reads an encrypted workbook yet. `bytes` is the
# whole container, in memory; the result is a named list with one raw vector
# per stream in `names`, or NULL where the container has no such stream.
cfb_streams <- function(bytes, names, path = NULL) {
  zuxlsx_unwrap(.Call(C_cfb_streams, bytes, names), path = path)
}
