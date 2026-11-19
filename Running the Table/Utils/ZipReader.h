#ifndef ZipReader_h
#define ZipReader_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// libarchive result codes, mirrored so callers never need the (absent) header;
// note libarchive's OK is 0 and EOF is 1, the reverse of most C APIs.
enum { ZIPREADER_OK = 0, ZIPREADER_EOF = 1, ZIPREADER_FAILED = -1 };

// Reads one file entry of a zip archive into a malloc'd buffer that
// zipreader_free releases. ZIPREADER_EOF when the entry is absent.
int zipreader_read_entry(const char *archivePath, const char *entryPath,
                         unsigned char **outData, int64_t *outSize);
void zipreader_free(void *data);

#ifdef __cplusplus
}
#endif

#endif
