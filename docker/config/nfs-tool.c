/*
 * nfs-tool — libnfs-based NFS file operations (no mount, no kernel support)
 *
 * Usage: nfs-tool <server> <cmd> <remote> [local]
 *   write  <remote> <local>  - upload (overwrite OK)
 *   read   <remote> <local>  - download
 *   rename <old> <new>       - atomic rename
 *   rm     <remote>          - delete file
 *   mkdir  <remote>          - create directory
 *   mkdirp <remote>          - create directory tree
 *   ls     [remote]          - list directory
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <nfsc/libnfs.h>

static int cmd_write(struct nfs_context *nfs, const char *remote, const char *local) {
    if (!local) { fprintf(stderr, "write needs local path\n"); return 1; }
    FILE *fp = fopen(local, "rb");
    if (!fp) { perror("fopen"); return 1; }

    struct nfsfh *fh = NULL;
    int rc = nfs_creat(nfs, remote, 0660, &fh);
    if (rc == -EEXIST)
        rc = nfs_open(nfs, remote, O_WRONLY | O_TRUNC, &fh);
    if (rc) {
        fprintf(stderr, "open %s: %s\n", remote, nfs_get_error(nfs));
        fclose(fp);
        return 1;
    }

    char buf[65536];
    size_t total = 0;
    int ret = 0;
    while (1) {
        size_t n = fread(buf, 1, sizeof(buf), fp);
        if (n == 0) break;
        int w = nfs_write(nfs, fh, n, buf);
        if (w < 0) {
            fprintf(stderr, "write: %s\n", nfs_get_error(nfs));
            ret = 1;
            break;
        }
        total += w;
    }
    nfs_close(nfs, fh);
    fclose(fp);
    if (!ret) printf("wrote %zu bytes to %s\n", total, remote);
    return ret;
}

static int cmd_read(struct nfs_context *nfs, const char *remote, const char *local) {
    if (!local) { fprintf(stderr, "read needs local path\n"); return 1; }

    struct nfsfh *fh = NULL;
    int rc = nfs_open(nfs, remote, O_RDONLY, &fh);
    if (rc) {
        fprintf(stderr, "open %s: %s\n", remote, nfs_get_error(nfs));
        return 1;
    }

    FILE *fp = fopen(local, "wb");
    if (!fp) { perror("fopen"); nfs_close(nfs, fh); return 1; }

    char buf[65536];
    size_t total = 0;
    while (1) {
        int n = nfs_read(nfs, fh, sizeof(buf), buf);
        if (n <= 0) break;
        fwrite(buf, 1, n, fp);
        total += n;
    }
    nfs_close(nfs, fh);
    fclose(fp);
    printf("read %zu bytes from %s\n", total, remote);
    return 0;
}

static int cmd_rename(struct nfs_context *nfs, const char *old_path, const char *new_path) {
    if (!new_path) { fprintf(stderr, "rename needs old and new path\n"); return 1; }
    int rc = nfs_rename(nfs, old_path, new_path);
    if (rc) {
        fprintf(stderr, "rename %s -> %s: %s\n", old_path, new_path, nfs_get_error(nfs));
        return 1;
    }
    printf("renamed %s -> %s\n", old_path, new_path);
    return 0;
}

static int cmd_rm(struct nfs_context *nfs, const char *remote) {
    int rc = nfs_unlink(nfs, remote);
    if (rc) { fprintf(stderr, "rm: %s\n", nfs_get_error(nfs)); return 1; }
    printf("deleted %s\n", remote);
    return 0;
}

static int cmd_mkdir(struct nfs_context *nfs, const char *remote) {
    int rc = nfs_mkdir(nfs, remote);
    if (rc) { fprintf(stderr, "mkdir: %s\n", nfs_get_error(nfs)); return 1; }
    printf("created %s\n", remote);
    return 0;
}

static int cmd_mkdirp(struct nfs_context *nfs, const char *remote) {
    char *path = strdup(remote);
    char *p = path;
    while (*p) {
        p++;
        while (*p && *p != '/') p++;
        char saved = *p;
        *p = '\0';
        struct nfs_stat_64 st;
        if (nfs_stat64(nfs, path, &st) != 0) {
            if (nfs_mkdir(nfs, path)) {
                fprintf(stderr, "mkdirp %s: %s\n", path, nfs_get_error(nfs));
                free(path);
                return 1;
            }
        }
        *p = saved;
        if (!saved) break;
    }
    free(path);
    printf("mkdirp %s done\n", remote);
    return 0;
}

static int cmd_ls(struct nfs_context *nfs, const char *remote) {
    struct nfsdir *dir = NULL;
    int rc = nfs_opendir(nfs, remote, &dir);
    if (rc) { fprintf(stderr, "ls: %s\n", nfs_get_error(nfs)); return 1; }
    struct nfsdirent *e;
    while ((e = nfs_readdir(nfs, dir))) {
        if (!strcmp(e->name, ".") || !strcmp(e->name, "..")) continue;
        printf("%c %10lu %s\n",
               S_ISDIR(e->mode) ? 'd' : '-',
               (unsigned long)e->size, e->name);
    }
    nfs_closedir(nfs, dir);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr,
            "Usage: %s <server> <cmd> <remote> [local]\n"
            "  write  <remote> <local>  - upload (overwrite OK)\n"
            "  read   <remote> <local>  - download\n"
            "  rename <old> <new>       - atomic rename\n"
            "  rm     <remote>          - delete file\n"
            "  mkdir  <remote>          - create directory\n"
            "  mkdirp <remote>          - create directory tree\n"
            "  ls     [remote]          - list directory\n",
            argv[0]);
        return 1;
    }

    const char *server = argv[1];
    const char *cmd    = argv[2];
    const char *arg1   = argc > 3 ? argv[3] : "/";
    const char *arg2   = argc > 4 ? argv[4] : NULL;

    struct nfs_context *nfs = nfs_init_context();
    if (!nfs) { fprintf(stderr, "nfs init failed\n"); return 1; }

    if (nfs_mount(nfs, server, "/")) {
        fprintf(stderr, "mount %s: %s\n", server, nfs_get_error(nfs));
        nfs_destroy_context(nfs);
        return 1;
    }

    int ret;
    if      (strcmp(cmd, "write")  == 0) ret = cmd_write(nfs, arg1, arg2);
    else if (strcmp(cmd, "read")   == 0) ret = cmd_read(nfs, arg1, arg2);
    else if (strcmp(cmd, "rename") == 0) ret = cmd_rename(nfs, arg1, arg2);
    else if (strcmp(cmd, "rm")     == 0) ret = cmd_rm(nfs, arg1);
    else if (strcmp(cmd, "mkdir")  == 0) ret = cmd_mkdir(nfs, arg1);
    else if (strcmp(cmd, "mkdirp") == 0) ret = cmd_mkdirp(nfs, arg1);
    else if (strcmp(cmd, "ls")     == 0) ret = cmd_ls(nfs, arg1);
    else { fprintf(stderr, "unknown command: %s\n", cmd); ret = 1; }

    nfs_umount(nfs);
    nfs_destroy_context(nfs);
    return ret;
}
