#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t volume;
    uint8_t file_id[16];
    int64_t logical_bytes, allocated_bytes, modified_ns, changed_ns;
    uint32_t attributes, links, kind, current_user;
    char owner_sid[192];
} shou_win_info;
typedef struct shou_win_lock shou_win_lock;
int shou_win_normalize(const char *path, char **result);
int shou_win_stat(const char *path, shou_win_info *result);
int shou_win_list(const char *path, size_t limit, char **result);
int shou_win_read(const char *path, size_t limit, void **bytes, size_t *count);
int shou_win_private_directory(const char *path);
int shou_win_write(const char *path, const void *bytes, size_t count);
int shou_win_remove_record(const char *path);
int shou_win_lock_acquire(const char *path, shou_win_lock **result);
void shou_win_lock_release(shou_win_lock *lock);
int shou_win_recycle(const char *path, const shou_win_info *expected, char **result);
int shou_win_restore(const char *path, const char *destination, const shou_win_info *expected, char **result);
typedef int (*shou_win_cancelled)(void);
int shou_win_purge(const char *path, const char *const *relative_paths, const char *const *content_digests, const shou_win_info *expected, size_t count, shou_win_cancelled cancelled, size_t *removed);
int shou_win_available(const char *path, uint64_t *result);
int shou_win_console_confirm(const char *review, const char *prompt, const char *phrase);
int shou_win_stdin(void *buffer, uint32_t capacity, uint32_t *count);
void shou_win_free(void *value);
#ifdef __cplusplus
}
#endif
