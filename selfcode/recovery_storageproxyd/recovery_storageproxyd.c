/*
 * Minimal persistent storage proxy daemon for Android recovery.
 *
 * Replaces the vendor storageproxyd for use in TWRP/OrangeFox recovery
 * where SystemSuspend (wakelock) service is unavailable.
 *
 * Key differences from vendor storageproxyd:
 *   - No binder/wakelock dependency
 *   - Reconnects to Trusty in a tight loop on disconnect
 *   - No checkpoint handling (not needed in recovery)
 *   - No watchdog (not needed in recovery)
 *   - Single-file, compilable with just a cross-compiler
 *
 * Compile:
 *   clang --target=aarch64-linux-android31 -O2 -o recovery_sp \
 *     recovery_storageproxyd.c -lc
 *
 * Usage:
 *   recovery_sp -d /dev/trusty-ipc-dev0 -r /dev/sg1 -p /tmp/ss
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/fs.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>


static void logmsg(const char *level, const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "[recovery_sp] %s: ", level);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

#define LOGI(...) logmsg("I", __VA_ARGS__)
#define LOGE(...) logmsg("E", __VA_ARGS__)
#define LOGD(...) do {} while(0)

#define TIPC_IOC_CONNECT  _IOW('r', 0x80, char *)

static int tipc_connect(const char *dev, const char *port) {
    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        LOGE("open(%s): %s\n", dev, strerror(errno));
        return -1;
    }
    int rc = ioctl(fd, TIPC_IOC_CONNECT, port);
    if (rc < 0) {
        LOGE("tipc_connect(%s): %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}


#define STORAGE_DISK_PROXY_PORT "com.android.trusty.storage.proxy"

enum storage_cmd {
    STORAGE_REQ_SHIFT = 1,
    STORAGE_RESP_BIT  = 1,
    STORAGE_RESP_MSG_ERR   = 1,
    STORAGE_FILE_DELETE    = 2,
    STORAGE_FILE_OPEN      = 4,
    STORAGE_FILE_CLOSE     = 6,
    STORAGE_FILE_READ      = 8,
    STORAGE_FILE_WRITE     = 10,
    STORAGE_FILE_GET_SIZE  = 12,
    STORAGE_FILE_SET_SIZE  = 14,
    STORAGE_RPMB_SEND      = 16,
    STORAGE_END_TRANSACTION = 18,
    STORAGE_FILE_GET_MAX_SIZE = 24,
};

enum storage_err {
    STORAGE_NO_ERROR          = 0,
    STORAGE_ERR_GENERIC       = 1,
    STORAGE_ERR_NOT_VALID     = 2,
    STORAGE_ERR_UNIMPLEMENTED = 3,
    STORAGE_ERR_ACCESS        = 4,
    STORAGE_ERR_NOT_FOUND     = 5,
    STORAGE_ERR_EXIST         = 6,
    STORAGE_ERR_TRANSACT      = 7,
    STORAGE_ERR_SYNC_FAILURE  = 8,
};

#define STORAGE_MSG_FLAG_BATCH                 0x1
#define STORAGE_MSG_FLAG_PRE_COMMIT            0x2
#define STORAGE_MSG_FLAG_POST_COMMIT           0x4
#define STORAGE_MSG_FLAG_TRANSACT_COMPLETE     0x4
#define STORAGE_MSG_FLAG_PRE_COMMIT_CHECKPOINT 0x8

struct storage_msg {
    uint32_t cmd;
    uint32_t op_id;
    uint32_t flags;
    uint32_t size;
    int32_t  result;
    uint32_t __reserved;
    uint8_t  payload[0];
};

struct storage_rpmb_send_req {
    uint32_t reliable_write_size;
    uint32_t write_size;
    uint32_t read_size;
    uint32_t __reserved;
    uint8_t  payload[0];
};

struct storage_file_delete_req {
    uint32_t flags;
    char name[0];
};

struct storage_file_open_req {
    uint32_t flags;
    char name[0];
};

struct storage_file_open_resp {
    uint32_t handle;
};

#define STORAGE_FILE_OPEN_CREATE           (1 << 0)
#define STORAGE_FILE_OPEN_CREATE_EXCLUSIVE (1 << 1)
#define STORAGE_FILE_OPEN_TRUNCATE         (1 << 2)

struct storage_file_close_req {
    uint32_t handle;
};

struct storage_file_read_req {
    uint32_t handle;
    uint32_t size;
    uint64_t offset;
};

struct storage_file_read_resp {
    uint8_t data[0];
};

struct storage_file_write_req {
    uint64_t offset;
    uint32_t handle;
    uint32_t __reserved;
    uint8_t  data[0];
};

struct storage_file_get_size_req {
    uint32_t handle;
};

struct storage_file_get_size_resp {
    uint64_t size;
};

struct storage_file_set_size_req {
    uint64_t size;
    uint32_t handle;
};

struct storage_file_get_max_size_req {
    uint32_t handle;
};

struct storage_file_get_max_size_resp {
    uint64_t max_size;
};

typedef struct sg_io_hdr {
    int interface_id;
    int dxfer_direction;
    unsigned char cmd_len;
    unsigned char mx_sb_len;
    unsigned short iovec_count;
    unsigned int dxfer_len;
    void *dxferp;
    unsigned char *cmdp;
    unsigned char *sbp;
    unsigned int timeout;
    unsigned int flags;
    int pack_id;
    void *usr_ptr;
    unsigned char status;
    unsigned char masked_status;
    unsigned char msg_status;
    unsigned char sb_len_wr;
    unsigned short host_status;
    unsigned short driver_status;
    int resid;
    unsigned int duration;
    unsigned int info;
} sg_io_hdr_t;

#define SG_IO           0x2285
#define SG_GET_VERSION_NUM 0x2282
#define SG_DXFER_NONE       -1
#define SG_DXFER_TO_DEV     -2
#define SG_DXFER_FROM_DEV   -3
#define RPMB_MIN_SG_VERSION 30000

struct __attribute__((packed)) sec_proto_cdb {
    uint8_t opcode;
    uint8_t sec_proto;
    uint8_t cdb_byte_2;
    uint8_t cdb_byte_3;
    uint8_t cdb_byte_4;
    uint8_t cdb_byte_5;
    uint32_t length;
    uint8_t cdb_byte_10;
    uint8_t ctrl;
};

#define SENSE_NO_SENSE      0x00
#define SENSE_UNIT_ATTENTION 0x06


#define REQ_BUFFER_SIZE 4096
#define MAX_READ_SIZE   4096
#define FD_TBL_SIZE     64
#define MMC_BLOCK_SIZE  512
#define MAX_FILE_SIZE   (0x10000000000ULL)
#define UFS_WRITE_RETRY 1
#define UFS_READ_RETRY  3
#define SG_TIMEOUT      20000

static uint8_t req_buffer[REQ_BUFFER_SIZE + 1];
static uint8_t rpmb_read_buf[4096];
static uint8_t file_read_buf[MAX_READ_SIZE + sizeof(struct storage_file_read_resp)];

static const char *trusty_devname;
static const char *rpmb_devname;
static const char *ss_data_root;

static int rpmb_fd = -1;
static int tipc_fd = -1;


static ssize_t ipc_get_msg(struct storage_msg *msg, void *req_buf, size_t req_buf_len) {
    struct iovec iovs[2] = {{msg, sizeof(*msg)}, {req_buf, req_buf_len}};
    ssize_t rc = readv(tipc_fd, iovs, 2);
    if (rc < 0) return rc;
    if ((size_t)rc < sizeof(*msg)) return -1;
    if (msg->size != (uint32_t)rc) return -1;
    return rc - sizeof(*msg);
}

static int ipc_respond(struct storage_msg *msg, void *out, size_t out_size) {
    msg->cmd |= STORAGE_RESP_BIT;
    struct iovec iovs[2] = {{msg, sizeof(*msg)}, {out, out_size}};
    msg->size = sizeof(*msg) + out_size;
    ssize_t rc = writev(tipc_fd, iovs, out_size ? 2 : 1);
    return (rc < 0) ? (int)rc : 0;
}


static void setup_sg_io(sg_io_hdr_t *h, int dir, unsigned char cdb_len,
                        unsigned int dxfer_len, void *dxferp,
                        unsigned char *cmdp, void *sbp, unsigned char sb_len) {
    memset(h, 0, sizeof(*h));
    h->interface_id = 'S';
    h->dxfer_direction = dir;
    h->cmd_len = cdb_len;
    h->mx_sb_len = sb_len;
    h->dxfer_len = dxfer_len;
    h->dxferp = dxferp;
    h->cmdp = cmdp;
    h->sbp = sbp;
    h->timeout = SG_TIMEOUT;
}

static int check_sg_result(const sg_io_hdr_t *h) {
    if (h->status == 0 && h->host_status == 0 && h->driver_status == 0)
        return 0;
    if (h->sb_len_wr > 0) {
        const uint8_t *sb = h->sbp;
        uint8_t resp = sb[0] & 0x7f;
        uint8_t sense_key = 0;
        uint8_t asc = 0;
        if (resp >= 0x72) { /* descriptor format */
            if (h->sb_len_wr > 1) sense_key = sb[1] & 0x0f;
            if (h->sb_len_wr > 2) asc = sb[2];
        } else if (resp >= 0x70) { /* fixed format */
            if (h->sb_len_wr > 2) sense_key = sb[2] & 0x0f;
            if (h->sb_len_wr > 12) asc = sb[12];
        }
        if (sense_key == SENSE_NO_SENSE || sense_key == 0x0f)
            return 0;
        if (sense_key == SENSE_UNIT_ATTENTION && asc == 0x29)
            return 1;
    }
    LOGE("SG_IO error: status=%u masked=%u host=%u drv=%u\n",
            h->status, h->masked_status, h->host_status, h->driver_status);
    return -1;
}

static int send_ufs_rpmb(const struct storage_rpmb_send_req *req) {
    struct sec_proto_cdb in_cdb  = {0xA2, 0xEC, 0, 1, 0, 0, 0, 0, 0};
    struct sec_proto_cdb out_cdb = {0xB5, 0xEC, 0, 1, 0, 0, 0, 0, 0};
    unsigned char sense[32];
    sg_io_hdr_t io;
    int rc;
    const uint8_t *write_buf = req->payload;
    bool is_req_write = req->reliable_write_size > 0;

    if (req->reliable_write_size) {
        int retry = UFS_WRITE_RETRY;
        do {
            out_cdb.length = __builtin_bswap32(req->reliable_write_size);
            setup_sg_io(&io, SG_DXFER_TO_DEV, sizeof(out_cdb),
                        req->reliable_write_size, (void*)write_buf,
                        (unsigned char*)&out_cdb, sense, sizeof(sense));
            rc = ioctl(rpmb_fd, SG_IO, &io);
            if (rc < 0) { LOGE("SG_IO reliable_write: %s\n", strerror(errno)); return rc; }
        } while (check_sg_result(&io) == 1 && retry-- > 0);
        write_buf += req->reliable_write_size;
    }

    if (req->write_size) {
        int retry = is_req_write ? 0 : UFS_READ_RETRY;
        do {
            out_cdb.length = __builtin_bswap32(req->write_size);
            setup_sg_io(&io, SG_DXFER_TO_DEV, sizeof(out_cdb),
                        req->write_size, (void*)write_buf,
                        (unsigned char*)&out_cdb, sense, sizeof(sense));
            rc = ioctl(rpmb_fd, SG_IO, &io);
            if (rc < 0) { LOGE("SG_IO write: %s\n", strerror(errno)); return rc; }
        } while (check_sg_result(&io) == 1 && retry-- > 0);
        write_buf += req->write_size;
    }

    if (req->read_size) {
        in_cdb.length = __builtin_bswap32(req->read_size);
        setup_sg_io(&io, SG_DXFER_FROM_DEV, sizeof(in_cdb),
                    req->read_size, rpmb_read_buf,
                    (unsigned char*)&in_cdb, sense, sizeof(sense));
        rc = ioctl(rpmb_fd, SG_IO, &io);
        if (rc < 0) { LOGE("SG_IO read: %s\n", strerror(errno)); return rc; }
        check_sg_result(&io);
    }

    return 0;
}


static ssize_t write_full(int fd, const void *buf_, size_t sz, off_t off) {
    const uint8_t *b = buf_;
    while (sz > 0) {
        ssize_t n = pwrite(fd, b, sz, off);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        sz -= n; b += n; off += n;
    }
    return 0;
}

static ssize_t read_full(int fd, void *buf_, size_t sz, off_t off) {
    uint8_t *b = buf_;
    ssize_t total = 0;
    while (sz > 0) {
        ssize_t n = pread(fd, b, sz, off);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) break;
        sz -= n; b += n; off += n; total += n;
    }
    return total;
}

static enum storage_err translate_errno(int err) {
    switch (err) {
    case 0:       return STORAGE_NO_ERROR;
    case ENOENT:  return STORAGE_ERR_NOT_FOUND;
    case EEXIST:  return STORAGE_ERR_EXIST;
    case EACCES:
    case EPERM:   return STORAGE_ERR_ACCESS;
    case EBADF:
    case EINVAL:
    case ENOTDIR:
    case ENAMETOOLONG: return STORAGE_ERR_NOT_VALID;
    default:      return STORAGE_ERR_GENERIC;
    }
}

static void sync_parent_dir(const char *path) {
    char tmp[512];
    strncpy(tmp, path, sizeof(tmp)-1);
    tmp[sizeof(tmp)-1] = 0;
    /* Find last slash */
    char *sl = strrchr(tmp, '/');
    if (sl) {
        *sl = 0;
        int fd = open(tmp, O_RDONLY);
        if (fd >= 0) { fsync(fd); close(fd); }
    }
}


static int handle_rpmb_send(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_rpmb_send_req *req = r;
    if (req_len < sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    size_t expected = sizeof(*req) + req->reliable_write_size + req->write_size;
    if (req_len != expected) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    if ((req->reliable_write_size % MMC_BLOCK_SIZE) ||
        (req->write_size % MMC_BLOCK_SIZE) ||
        (req->read_size % MMC_BLOCK_SIZE) ||
        (req->read_size > sizeof(rpmb_read_buf))) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }

    int rc = send_ufs_rpmb(req);
    if (rc < 0) {
        msg->result = STORAGE_ERR_GENERIC;
        return ipc_respond(msg, NULL, 0);
    }
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, rpmb_read_buf, req->read_size);
}

static int handle_file_delete(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_delete_req *req = r;
    if (req_len < sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    size_t fname_len = strlen(req->name);
    if (fname_len != req_len - sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", ss_data_root, req->name);
    int rc = unlink(path);
    msg->result = (rc < 0) ? translate_errno(errno) : STORAGE_NO_ERROR;
    return ipc_respond(msg, NULL, 0);
}

static int handle_file_open(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_open_req *req = r;
    struct storage_file_open_resp resp = {0};
    if (req_len < sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    size_t fname_len = strlen(req->name);
    if (fname_len != req_len - sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }

    char path[512];
    snprintf(path, sizeof(path), "%s/%s", ss_data_root, req->name);

    int open_flags = O_RDWR;
    if (req->flags & STORAGE_FILE_OPEN_TRUNCATE)
        open_flags |= O_TRUNC;

    int fd;
    if (req->flags & STORAGE_FILE_OPEN_CREATE) {
        char *slash = strrchr(path + strlen(ss_data_root) + 1, '/');
        if (slash) {
            *slash = 0;
            mkdir(path, 0700);
            sync_parent_dir(path);
            *slash = '/';
        }

        if (req->flags & STORAGE_FILE_OPEN_CREATE_EXCLUSIVE) {
            fd = open(path, open_flags | O_CREAT | O_EXCL, 0600);
        } else {
            fd = open(path, open_flags, 0600);
            if (fd < 0 && errno == ENOENT)
                fd = open(path, open_flags | O_CREAT, 0600);
        }
    } else {
        fd = open(path, open_flags, 0600);
    }

    if (fd < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    if (open_flags & O_CREAT)
        sync_parent_dir(path);

    resp.handle = (uint32_t)fd;
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, &resp, sizeof(resp));
}

static int handle_file_close(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_close_req *req = r;
    if (req_len != sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    int fd = (int)req->handle;
    fsync(fd);
    int rc = close(fd);
    msg->result = (rc < 0) ? translate_errno(errno) : STORAGE_NO_ERROR;
    return ipc_respond(msg, NULL, 0);
}

static int handle_file_read(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_read_req *req = r;
    if (req_len != sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    if (req->size > MAX_READ_SIZE) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    ssize_t n = read_full((int)req->handle,
                            file_read_buf + sizeof(struct storage_file_read_resp),
                            req->size, (off_t)req->offset);
    if (n < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, file_read_buf, n + sizeof(struct storage_file_read_resp));
}

static int handle_file_write(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_write_req *req = r;
    if (req_len < sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    int fd = (int)req->handle;
    size_t data_len = req_len - sizeof(*req);
    if (write_full(fd, req->data, data_len, (off_t)req->offset) < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    if (msg->flags & STORAGE_MSG_FLAG_POST_COMMIT) {
        int i;
        for (i = 0; i < FD_TBL_SIZE; i++) {
        }
        sync();
    }
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, NULL, 0);
}

static int handle_file_get_size(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_get_size_req *req = r;
    struct storage_file_get_size_resp resp = {0};
    if (req_len != sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    struct stat st;
    if (fstat((int)req->handle, &st) < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    resp.size = st.st_size;
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, &resp, sizeof(resp));
}

static int handle_file_set_size(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_set_size_req *req = r;
    if (req_len != sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    if (ftruncate((int)req->handle, (off_t)req->size) < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, NULL, 0);
}

static int handle_file_get_max_size(struct storage_msg *msg, const void *r, size_t req_len) {
    const struct storage_file_get_max_size_req *req = r;
    struct storage_file_get_max_size_resp resp = {0};
    if (req_len != sizeof(*req)) {
        msg->result = STORAGE_ERR_NOT_VALID;
        return ipc_respond(msg, NULL, 0);
    }
    struct stat st;
    if (fstat((int)req->handle, &st) < 0) {
        msg->result = translate_errno(errno);
        return ipc_respond(msg, NULL, 0);
    }
    if (S_ISBLK(st.st_mode)) {
        uint64_t sz;
        if (ioctl((int)req->handle, BLKGETSIZE64, &sz) < 0) {
            msg->result = translate_errno(errno);
            return ipc_respond(msg, NULL, 0);
        }
        resp.max_size = sz;
    } else {
        resp.max_size = MAX_FILE_SIZE;
    }
    msg->result = STORAGE_NO_ERROR;
    return ipc_respond(msg, &resp, sizeof(resp));
}


static int handle_req(struct storage_msg *msg, const void *req, size_t req_len) {
    /* Handle pre-commit sync */
    if (msg->flags & STORAGE_MSG_FLAG_PRE_COMMIT) {
        sync();
    }

    switch (msg->cmd) {
    case STORAGE_RPMB_SEND:      return handle_rpmb_send(msg, req, req_len);
    case STORAGE_FILE_DELETE:     return handle_file_delete(msg, req, req_len);
    case STORAGE_FILE_OPEN:       return handle_file_open(msg, req, req_len);
    case STORAGE_FILE_CLOSE:      return handle_file_close(msg, req, req_len);
    case STORAGE_FILE_READ:       return handle_file_read(msg, req, req_len);
    case STORAGE_FILE_WRITE:      return handle_file_write(msg, req, req_len);
    case STORAGE_FILE_GET_SIZE:   return handle_file_get_size(msg, req, req_len);
    case STORAGE_FILE_SET_SIZE:   return handle_file_set_size(msg, req, req_len);
    case STORAGE_FILE_GET_MAX_SIZE: return handle_file_get_max_size(msg, req, req_len);
    default:
        LOGE("unhandled command 0x%x\n", msg->cmd);
        msg->result = STORAGE_ERR_UNIMPLEMENTED;
        return ipc_respond(msg, NULL, 0);
    }
}


static int proxy_loop(void) {
    while (1) {
        struct storage_msg msg;
        ssize_t rc = ipc_get_msg(&msg, req_buffer, REQ_BUFFER_SIZE);
        if (rc < 0) return (int)rc;
        req_buffer[rc] = 0;
        rc = handle_req(&msg, req_buffer, rc);
        if (rc) return (int)rc;
    }
}


static void usage(void) {
    fprintf(stderr, "Usage: recovery_sp -d <trusty_dev> -r <rpmb_dev> -p <data_path>\n");
    exit(1);
}

static void parse_args(int argc, char *argv[]) {
    int opt;
    while ((opt = getopt(argc, argv, "d:r:p:")) != -1) {
        switch (opt) {
        case 'd': trusty_devname = optarg; break;
        case 'r': rpmb_devname  = optarg; break;
        case 'p': ss_data_root  = optarg; break;
        default:  usage();
        }
    }
    if (!trusty_devname || !rpmb_devname || !ss_data_root)
        usage();
}


int main(int argc, char *argv[]) {
    int rc;

    umask(S_IRWXG | S_IRWXO);
    parse_args(argc, argv);

    LOGI("starting: trusty=%s rpmb=%s data=%s\n", trusty_devname, rpmb_devname, ss_data_root);

    mkdir(ss_data_root, 0700);
    {
        char persist[512];
        snprintf(persist, sizeof(persist), "%s/persist", ss_data_root);
        mkdir(persist, 0700);
    }

    rpmb_fd = open(rpmb_devname, O_RDWR);
    if (rpmb_fd < 0) {
        LOGE("cannot open RPMB device %s: %s\n", rpmb_devname, strerror(errno));
        return 1;
    }
    {
        int sg_ver;
        if (ioctl(rpmb_fd, SG_GET_VERSION_NUM, &sg_ver) < 0 || sg_ver < RPMB_MIN_SG_VERSION) {
            LOGE("%s is not a valid sg device\n", rpmb_devname);
            return 1;
        }
        LOGI("SG version: %d\n", sg_ver);
    }

    int connect_failures = 0;
    bool first_connect = true;
    while (1) {
        tipc_fd = tipc_connect(trusty_devname, STORAGE_DISK_PROXY_PORT);
        if (tipc_fd < 0) {
            connect_failures++;
            if (connect_failures > 100) {
                LOGE("too many connect failures, sleeping 1s\n");
                sleep(1);
                connect_failures = 0;
            } else {
                usleep(1000);
            }
            continue;
        }
        connect_failures = 0;
        LOGD("connected to Trusty storage\n");

        if (first_connect) {
            int rfd = open("/dev/.recovery_sp_ready", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (rfd >= 0) close(rfd);
            first_connect = false;
            LOGI("ready (signaled /dev/.recovery_sp_ready)\n");
        }

        rc = proxy_loop();
        LOGD("proxy_loop exited: %d\n", rc);

        close(tipc_fd);
        tipc_fd = -1;

    }

    close(rpmb_fd);
    return 0;
}
