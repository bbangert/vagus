/*
 * vagus_walk <root>: stream every entry under <root> to the BEAM as
 * {packet, 4} frames (the protocol is documented in Vagus.Backup.Walk).
 *
 * The kernel enforces the boundary, not path checks: every open is
 * openat2(parent_fd, name, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS), so an app
 * that swaps a directory for a symlink between our listing and our open gets
 * ELOOP instead of a walk into host files as root. A path-based
 * lstat-then-open cannot close that window; a descriptor-relative open can.
 *
 * A symlink is reported as skipped, not as an error: apps legitimately keep
 * symlinks in their data and upstream backups never follow them either, so an
 * error would make such an app unbackupable, while dropping it silently would
 * hide the skip. A real read error stops the walk: never an incomplete backup.
 *
 * Each entry is first opened O_PATH and typed by fstat; only a regular file
 * or directory is reopened for reading, and must be the same inode. A fifo
 * opened O_RDONLY blocks and a device open can have side effects.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#ifndef RESOLVE_NO_SYMLINKS
#define RESOLVE_NO_SYMLINKS 0x04
#endif
#ifndef RESOLVE_BENEATH
#define RESOLVE_BENEATH 0x08
#endif

/* Local definition: libc headers that ship one vary, and some ship none. */
struct vw_open_how { uint64_t flags, mode, resolve; };

#define CHUNK 65536
#define REL_MAX 4096

static unsigned char frame[5 + CHUNK];

static int open2(int dirfd, const char *path, uint64_t flags, uint64_t resolve)
{
    struct vw_open_how how = {.flags = flags, .mode = 0, .resolve = resolve};
    return (int) syscall(SYS_openat2, dirfd, path, &how, sizeof how);
}

static void write_all(const unsigned char *p, size_t n)
{
    while (n > 0) {
        ssize_t w = write(STDOUT_FILENO, p, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0)
            exit(2);
        p += w;
        n -= (size_t) w;
    }
}

static void put_len(size_t len)
{
    for (int i = 0; i < 4; i++)
        frame[i] = (unsigned char) (len >> (24 - 8 * i));
}

/* A frame is the tag byte, then the non-NULL fields joined by NUL. */
static void emit(char tag, const char *a, const char *b, const char *c, const char *d)
{
    const char *fields[] = {a, b, c, d};
    size_t len = 1;
    frame[4] = (unsigned char) tag;
    for (int i = 0; i < 4 && fields[i]; i++) {
        size_t n = strlen(fields[i]);
        if (i > 0)
            frame[4 + len++] = 0;
        if (len + n > CHUNK)
            exit(2);
        memcpy(frame + 4 + len, fields[i], n);
        len += n;
    }
    put_len(len);
    write_all(frame, 4 + len);
}

static const char *errname(int e)
{
    static const struct { int e; const char *name; } names[] = {
        {EIO, "eio"}, {EACCES, "eacces"}, {EPERM, "eperm"}, {ENOMEM, "enomem"},
        {EMFILE, "emfile"}, {ENFILE, "enfile"}, {ENAMETOOLONG, "enametoolong"},
        {ENOTDIR, "enotdir"}, {ENOSYS, "enosys"}, {EINVAL, "einval"}, {ESTALE, "estale"},
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (names[i].e == e)
            return names[i].name;
    return "eother";
}

static void fail(const char *rel, int e)
{
    emit('X', rel, errname(e), NULL, NULL);
    exit(1);
}

static const char *skip_reason(mode_t m)
{
    return S_ISLNK(m) ? "symlink" : S_ISFIFO(m) ? "fifo" : S_ISSOCK(m) ? "socket"
         : (S_ISCHR(m) || S_ISBLK(m)) ? "device" : "other";
}

/* Returns 1 when the open hit a resolve-flag refusal or a vanished name. */
static int skippable_open_error(const char *rel, int e)
{
    const char *why = e == ELOOP ? "eloop" : e == EXDEV ? "exdev" : e == ENOENT ? "enoent" : NULL;
    if (why)
        emit('S', rel, why, NULL, NULL);
    return why != NULL;
}

static void send_file(int fd, const char *rel, const struct stat *st)
{
    char mode[16], mtime[32], size[32];
    snprintf(mode, sizeof mode, "%u", (unsigned) (st->st_mode & 07777));
    snprintf(mtime, sizeof mtime, "%lld", (long long) st->st_mtime);
    snprintf(size, sizeof size, "%lld", (long long) st->st_size);
    emit('F', rel, mode, mtime, size);

    /* Capped at the announced size so a growing file can't overrun it; a
     * shrinking one just ends early and the reader keeps what arrived. */
    off_t left = st->st_size;
    while (left > 0) {
        size_t want = left < CHUNK ? (size_t) left : CHUNK;
        ssize_t n = read(fd, frame + 5, want);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0)
            fail(rel, errno);
        if (n == 0)
            break;
        put_len((size_t) n + 1);
        frame[4] = 'C';
        write_all(frame, 5 + (size_t) n);
        left -= n;
    }
    emit('E', NULL, NULL, NULL, NULL);
}

/* -1 means the entry was reported as skipped. */
static int open_entry(int parent, const char *name, const char *rel, uint64_t flags)
{
    int fd = open2(parent, name, flags, RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
    if (fd < 0 && !skippable_open_error(rel, errno))
        fail(rel, errno);
    return fd;
}

static void walk(int dirfd, const char *prefix);

static void visit(int parent, const char *name, const char *rel)
{
    struct stat probe, st;
    int pfd = open_entry(parent, name, rel, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (pfd < 0)
        return;
    if (fstat(pfd, &probe) < 0)
        fail(rel, errno);
    close(pfd);

    int is_dir = S_ISDIR(probe.st_mode);
    if (!is_dir && !S_ISREG(probe.st_mode)) {
        emit('S', rel, skip_reason(probe.st_mode), NULL, NULL);
        return;
    }

    uint64_t flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY | (is_dir ? O_DIRECTORY : 0);
    int fd = open_entry(parent, name, rel, flags);
    if (fd < 0)
        return;
    if (fstat(fd, &st) < 0)
        fail(rel, errno);
    /* The name may have been swapped between the two opens. */
    if (st.st_dev != probe.st_dev || st.st_ino != probe.st_ino) {
        emit('S', rel, "changed", NULL, NULL);
        close(fd);
        return;
    }

    if (is_dir) {
        emit('D', rel, NULL, NULL, NULL);
        walk(fd, rel);
    } else {
        send_file(fd, rel, &st);
    }
    close(fd);
}

static void walk(int dirfd, const char *prefix)
{
    int lfd = dup(dirfd);
    DIR *dir = lfd < 0 ? NULL : fdopendir(lfd);
    if (!dir)
        fail(prefix, errno);

    for (;;) {
        errno = 0;
        struct dirent *de = readdir(dir);
        if (!de) {
            if (errno)
                fail(prefix, errno);
            break;
        }
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;

        char rel[REL_MAX];
        int n = *prefix ? snprintf(rel, sizeof rel, "%s/%s", prefix, de->d_name)
                        : snprintf(rel, sizeof rel, "%s", de->d_name);
        if (n < 0 || (size_t) n >= sizeof rel)
            fail(prefix, ENAMETOOLONG);
        visit(dirfd, de->d_name, rel);
    }
    closedir(dir);
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 64;
    int root = open2(AT_FDCWD, argv[1], O_PATH | O_DIRECTORY | O_CLOEXEC, RESOLVE_NO_SYMLINKS);
    if (root < 0)
        fail("", errno);
    int rfd = open2(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC,
                    RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
    if (rfd < 0)
        fail("", errno);
    close(root);

    walk(rfd, "");
    close(rfd);
    emit('Z', NULL, NULL, NULL, NULL);
    return 0;
}
