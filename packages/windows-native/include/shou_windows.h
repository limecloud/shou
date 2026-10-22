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
typedef struct shou_win_directory shou_win_directory;
typedef struct shou_win_privacy_access shou_win_privacy_access;
typedef struct shou_win_managed_image shou_win_managed_image;
int shou_win_managed_image_acquire(const char *path, shou_win_info *identity, shou_win_managed_image **result);
void shou_win_managed_image_release(shou_win_managed_image *image);
int shou_win_privacy_directory(const char *path);
int shou_win_privacy_acquire(const char *home, const char *path, int writable, shou_win_privacy_access **result);
void shou_win_privacy_release(shou_win_privacy_access *access);
int shou_win_normalize(const char *path, char **result);
int shou_win_stat(const char *path, shou_win_info *result);
int shou_win_list(const char *path, size_t limit, char **result);
int shou_win_directory_open(const char *path, const shou_win_info *expected, shou_win_directory **result);
int shou_win_directory_next(shou_win_directory *directory, char **name);
int shou_win_directory_verify(shou_win_directory *directory, const shou_win_info *expected);
void shou_win_directory_close(shou_win_directory *directory);
int shou_win_read(const char *path, size_t limit, void **bytes, size_t *count);
int shou_win_preview_read(const char *path, const shou_win_info *expected, size_t limit, void **bytes, size_t *count);
/* Returns one reference to a read-only IStream that pins the reviewed file and ancestors. */
int shou_win_preview_stream(const char *root, const shou_win_info *root_expected, const char *path, const shou_win_info *expected, void **stream);
void shou_win_preview_stream_release(void *stream);
typedef void (*shou_win_preview_ready)(void *context);
int shou_win_preview_host(const char *path, void *stream, uint64_t parent_window, uint32_t parent_pid, shou_win_preview_ready ready, void *context);
typedef int (*shou_win_read_cancelled)(void *context);
int shou_win_hash(const char *path, const shou_win_info *expected, uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, char **result);
int shou_win_private_directory(const char *path);
int shou_win_create_private_catalog(const char *path);
int shou_win_write(const char *path, const void *bytes, size_t count);
int shou_win_remove_record(const char *path);
int shou_win_lock_acquire(const char *path, shou_win_lock **result);
void shou_win_lock_release(shou_win_lock *lock);
int shou_win_recycle(const char *path, const shou_win_info *expected, char **result);
int shou_win_restore(const char *path, const char *destination, const shou_win_info *expected, char **result);
typedef int (*shou_win_cancelled)(void);
int shou_win_list_bounded(const char *path, size_t limit, uint32_t milliseconds, char **result, int *truncated, shou_win_cancelled cancelled);
int shou_win_purge(const char *path, const char *const *relative_paths, const char *const *content_digests, const shou_win_info *expected, size_t count, shou_win_cancelled cancelled, size_t *removed);
int shou_win_available(const char *path, uint64_t *result);
int shou_win_process_running(const char *name, int *running);
typedef struct {
    uint32_t pid, session;
    uint64_t created;
    char owner_sid[192], executable_path[4096];
    shou_win_info executable_identity;
} shou_win_close_process;
int shou_win_close_process_inventory(const char *name, shou_win_close_process **result, size_t *count);
int shou_win_request_process_close(const char *name, const shou_win_close_process *expected, size_t count, shou_win_read_cancelled cancelled, void *context);
int shou_win_cleanup_tool_info(const char *home, const char *tool, char **path, shou_win_info *identity);
int shou_win_cleanup_tool_run(const char *home, uint32_t operation, const char *toolchain, const char *expected_path, const shou_win_info *expected,
    uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, char **output);
int shou_win_build_processes(const char *names, const char *project, char **result);
int shou_win_git_tracked(const char *path, int *tracked);
int shou_win_console_confirm(const char *review, const char *prompt, const char *phrase);
int shou_win_stdin(void *buffer, uint32_t capacity, uint32_t *count);
int shou_win_ai_credential_read(const char *account, void **bytes, size_t *count);
int shou_win_ai_credential_write(const char *account, const void *bytes, size_t count);
int shou_win_startup_inventory(int include_system, size_t limit, uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, char **result);
int shou_win_application_inventory(int include_system, size_t limit, uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, char **result);
int shou_win_application_uninstall_review(const char *source_id, const char *registration, const char *evidence_digest, char **result);
int shou_win_application_uninstall_execute(const char *source_id, const char *registration, const char *evidence_digest, const char *action_digest,
    uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, int *started, uint32_t *exit_code, int *restart_required);
int shou_win_package_data_review(const char *registration, const char *evidence_digest, shou_win_read_cancelled cancelled, void *context, shou_win_info *identity, char **result);
int shou_win_package_data_clear(const char *registration, const char *evidence_digest, const char *action_digest,
    uint32_t milliseconds, shou_win_read_cancelled cancelled, void *context, int *started, int *completed);
int shou_win_startup_task_control(const char *path, const char *expected_digest, int enabled, int *write_started);
void shou_win_free(void *value);
#ifdef __cplusplus
}
#endif
