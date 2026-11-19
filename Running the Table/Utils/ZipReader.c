// The system ships libarchive (bsdtar's backend) without a public header, so
// the entry points we need are declared here and linked via -larchive.
#include "ZipReader.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, off_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern const char *archive_entry_pathname(struct archive_entry *);
extern int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
extern int archive_read_free(struct archive *);

int zipreader_read_entry(const char *archivePath, const char *entryPath,
                         unsigned char **outData, int64_t *outSize) {
    *outData = NULL;
    *outSize = 0;
    struct archive *archive = archive_read_new();
    if (archive == NULL) { return ZIPREADER_FAILED; }
    archive_read_support_format_zip(archive);
    if (archive_read_open_filename(archive, archivePath, 0) != ZIPREADER_OK) {
        archive_read_free(archive);
        return ZIPREADER_FAILED;
    }

    struct archive_entry *entry;
    int result = ZIPREADER_EOF;
    while ((result = archive_read_next_header(archive, &entry)) == ZIPREADER_OK) {
        if (strcmp(archive_entry_pathname(entry), entryPath) != 0) { continue; }

        size_t size = 0;
        int64_t offset = 0;
        const void *block;
        size_t capacity = 0;
        unsigned char *buffer = (unsigned char *)malloc(1);
        if (buffer == NULL) { result = ZIPREADER_FAILED; break; }
        while ((result = archive_read_data_block(archive, &block, &size, &offset)) == ZIPREADER_OK) {
            if (size == 0) { continue; }
            if (size > capacity) {
                capacity = size > 4096 ? size : 4096;
                unsigned char *grown = (unsigned char *)realloc(buffer, capacity);
                if (grown == NULL) { free(buffer); result = ZIPREADER_FAILED; break; }
                buffer = grown;
            }
            memcpy(buffer + *outSize, block, size);
            *outSize += (int64_t)size;
        }
        if (result == ZIPREADER_EOF) {
            *outData = buffer;
            result = ZIPREADER_OK;
        } else {
            free(buffer);
        }
        break;
    }
    archive_read_free(archive);
    return result;
}

void zipreader_free(void *data) {
    free(data);
}
