// Minimal declarations from libarchive's public archive.h and archive_entry.h.
// https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct archive;
struct archive_entry;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_RAW 0x90000
#define ARCHIVE_FILTER_NONE 0
#define AE_IFREG 0100000
#define AE_IFDIR 0040000
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_filter_by_code(struct archive *, int);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_format(struct archive *);
int archive_filter_code(struct archive *, int);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_birthtime_is_set(struct archive_entry *);
time_t archive_entry_birthtime(struct archive_entry *);
long archive_entry_birthtime_nsec(struct archive_entry *);

static inline uint64_t forel_process_start_time(int pid) {
    struct proc_bsdinfo info;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
