/*
 * vagus_walk <root>: stream every entry under <root> to the BEAM as
 * {packet, 4} frames (the protocol is documented in Vagus.Backup.Walk).
 *
 * The kernel enforces the boundary: every open is relative to the parent's
 * descriptor with RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS, so a directory
 * swapped for a symlink mid-walk is refused (ELOOP), not followed as root. A
 * directory moved out of the root mid-walk stays walkable through its
 * descriptor, but that rename crosses mounts, which only host root can do.
 *
 * Symlinks are skipped, as upstream backups do; a real read error stops the
 * walk, since an incomplete backup must never look complete.
 *
 * Each entry is typed by fstat on an O_PATH descriptor, and only a regular
 * file or directory is reopened, through that descriptor, never the name: a
 * fifo renamed in between would block the open, a device node's open can act.
 *
 * Every frame but X and Z waits for an ack on stdin: a port has no
 * inbound flow control, so otherwise the walker outruns the owner's mailbox.
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
/* Local copies of the kernel ABI: not every libc ships linux/openat2.h. */
enum { VW_NO_XDEV = 0x01, VW_NO_SYMLINKS = 0x04, VW_BENEATH = 0x08 };
struct vw_open_how { uint64_t flags, mode, resolve; };

#define CHUNK 65536
#define REL_MAX 4096
#define DEPTH_MAX 64 /* bounds the fds and stack a hostile tree makes us hold */

/* NO_XDEV: only an already-privileged party can mount inside a data dir, and
 * a stalled network mount would hang the walker. Like tar --one-file-system. */
#define RESOLVE_ENTRY (VW_BENEATH | VW_NO_SYMLINKS | VW_NO_XDEV)

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

/* The ack is an empty frame: one 4-byte pipe write, so it is read whole. */
static void put_frame(size_t len, int ack)
{
    unsigned char b[4];
    ssize_t n = 4;
    for (int i = 0; i < 4; i++)
        frame[i] = (unsigned char) (len >> (24 - 8 * i));
    write_all(frame, 4 + len);
    while (ack && (n = read(STDIN_FILENO, b, sizeof b)) < 0 && errno == EINTR)
        ;
    if (n != 4)
        exit(2);
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
    put_frame(len, tag != 'X' && tag != 'Z');
}

static const char *errname(int e)
{
    static const struct { int e; const char *name; } names[] = {
        {EIO, "eio"}, {EACCES, "eacces"}, {EPERM, "eperm"}, {ENOMEM, "enomem"},
        {EMFILE, "emfile"}, {ENFILE, "enfile"}, {ENAMETOOLONG, "enametoolong"},
        {ENOTDIR, "enotdir"}, {ENOSYS, "enosys"}, {EINVAL, "einval"}, {ESTALE, "estale"},
        {ENOENT, "enoent"}, {ELOOP, "eloop"}, {EXDEV, "exdev"},
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

static void skip(const char *rel, const char *why, int fd)
{
    emit('S', rel, why, NULL, NULL);
    if (fd >= 0)
        close(fd);
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
        frame[4] = 'C';
        put_frame((size_t) n + 1, 1);
        left -= n;
    }
    emit('E', NULL, NULL, NULL, NULL);
}

static void walk(int fd, const char *prefix, int depth);

static void visit(int parent, const char *name, const char *rel, int depth)
{
    struct stat probe, st;
    int pfd = open2(parent, name, O_PATH | O_NOFOLLOW | O_CLOEXEC, RESOLVE_ENTRY);
    if (pfd < 0) {
        /* A resolve-flag refusal or a name that vanished since readdir. */
        if (errno != ELOOP && errno != EXDEV && errno != ENOENT)
            fail(rel, errno);
        skip(rel, errname(errno), -1);
        return;
    }
    if (fstat(pfd, &probe) < 0)
        fail(rel, errno);

    int is_dir = S_ISDIR(probe.st_mode);
    const char *why = !is_dir && !S_ISREG(probe.st_mode) ? skip_reason(probe.st_mode)
                    : is_dir && depth > DEPTH_MAX ? "depth" : NULL;
    if (why) {
        skip(rel, why, pfd);
        return;
    }

    /* Through /proc there is no second name lookup to race. Without /proc
     * this fails and the walk stops with an X error; it never falls back to
     * the name. O_NONBLOCK never affects regular-file or directory reads. */
    char self[32];
    snprintf(self, sizeof self, "/proc/self/fd/%d", pfd);
    int fd = open(self, O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK | (is_dir ? O_DIRECTORY : 0));
    if (fd < 0)
        fail(rel, errno);
    close(pfd);
    if (fstat(fd, &st) < 0)
        fail(rel, errno);
    if (st.st_dev != probe.st_dev || st.st_ino != probe.st_ino) {
        skip(rel, "changed", fd);
        return;
    }

    if (is_dir) {
        emit('D', rel, NULL, NULL, NULL);
        walk(fd, rel, depth);
    } else {
        send_file(fd, rel, &st);
        close(fd);
    }
}

/* Takes ownership of fd: closedir closes it. */
static void walk(int fd, const char *prefix, int depth)
{
    DIR *dir = fdopendir(fd);
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
        visit(dirfd(dir), de->d_name, rel, depth + 1);
    }
    closedir(dir);
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 64;
    /* No NO_XDEV here: the data dir may itself be a mount. */
    int rfd = open2(AT_FDCWD, argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC, VW_NO_SYMLINKS);
    if (rfd < 0)
        fail("", errno);

    walk(rfd, "", 0);
    emit('Z', NULL, NULL, NULL, NULL);
    return 0;
}
