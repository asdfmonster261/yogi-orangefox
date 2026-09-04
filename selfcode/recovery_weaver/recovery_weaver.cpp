/*
 * recovery_weaver - A14-native Weaver HAL proxy for Pixel recovery
 *
 * Talks to the GSC (Titan) directly via /dev/gsc0 one_pass_call ioctl and
 * registers IWeaver/default on binder for CE FBE decryption.
 *
 * The GSC weaver app (APP_ID 0x03) does not use protobuf here: Titan M3 speaks
 * raw little-endian structs, each prefixed with a fixed 4-byte header word.
 *   getConfig reply : [u32 hdr][u32 slots][u32 keySize][u32 valueSize]
 *   read request    : [u32 hdr][u32 slot][u8 key[16]]
 *   read reply      : [u32 hdr][u32 error][u32 throttle][u32 rsvd][u8 value[16]]
 * error 0 means the key matched and value holds the escrowed secret. The header
 * word is not validated by the app; we send the value the config path returns.
 */

#define LOG_TAG "recovery_weaver"

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <aidl/android/hardware/weaver/BnWeaver.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <vector>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>


#define CITADEL_IOC_MAGIC 'c'

struct gsa_ioc_nos_call_req {
    uint8_t  app_id;
    uint8_t  reserved;
    uint16_t params;
    uint32_t arg_len;
    uint64_t buf;
    uint32_t reply_len;
    uint32_t call_status;
};

#define GSC_IOC_GSA_NOS_CALL _IOW(CITADEL_IOC_MAGIC, 3, struct gsa_ioc_nos_call_req)
#define MAX_GSA_NOS_CALL_TRANSFER 4096

#define APP_ID_WEAVER     0x03
#define APP_SUCCESS       0

#define WEAVER_GET_CONFIG 0
#define WEAVER_WRITE      1
#define WEAVER_READ       2

// The header word the GSC prefixes every weaver message with. Constant, and the
// app does not check it on input, so any value works; keep the observed one.
#define WEAVER_MSG_HDR    0x000e0000u


static inline uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
    p[2] = (uint8_t)((v >> 16) & 0xff);
    p[3] = (uint8_t)((v >> 24) & 0xff);
}


static int gsc_fd = -1;
static uint8_t gsa_nos_call_buf[MAX_GSA_NOS_CALL_TRANSFER];

static int gsc_open(const char *dev_path) {
    int fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        PLOG(ERROR) << "Failed to open " << dev_path;
        return -errno;
    }
    struct gsa_ioc_nos_call_req probe = {};
    probe.buf = reinterpret_cast<uint64_t>(gsa_nos_call_buf);
    int ret = ioctl(fd, GSC_IOC_GSA_NOS_CALL, &probe);
    if (ret < 0 && (errno == EINVAL || errno == ENOTTY)) {
        LOG(ERROR) << "GSC does not support one_pass_call";
        close(fd);
        return -ENOTSUP;
    }
    gsc_fd = fd;
    LOG(INFO) << "Opened " << dev_path << " fd=" << fd;
    return 0;
}

static int nos_call(uint8_t app_id, uint16_t params,
                    const uint8_t *args, uint32_t arg_len,
                    uint8_t *reply, uint32_t *reply_len,
                    uint32_t *call_status) {
    if (gsc_fd < 0) return -ENODEV;
    if (arg_len > MAX_GSA_NOS_CALL_TRANSFER) return -E2BIG;
    if (reply_len && *reply_len > MAX_GSA_NOS_CALL_TRANSFER) return -E2BIG;

    struct gsa_ioc_nos_call_req req = {};
    req.app_id   = app_id;
    req.params   = params;
    req.arg_len  = arg_len;
    req.buf      = reinterpret_cast<uint64_t>(gsa_nos_call_buf);
    req.reply_len = reply_len ? *reply_len : 0;

    if (arg_len && args) {
        memcpy(gsa_nos_call_buf, args, arg_len);
    }

    int ret = ioctl(gsc_fd, GSC_IOC_GSA_NOS_CALL, &req);
    if (ret < 0) {
        PLOG(ERROR) << "GSC ioctl failed: app=0x" << std::hex << (int)app_id
                    << " cmd=" << std::dec << params;
        return -errno;
    }

    *call_status = req.call_status;
    if (reply_len) {
        *reply_len = req.reply_len;
        if (*reply_len && reply) {
            memcpy(reply, gsa_nos_call_buf, *reply_len);
        }
    }
    return 0;
}


using aidl::android::hardware::weaver::BnWeaver;
using aidl::android::hardware::weaver::WeaverConfig;
using aidl::android::hardware::weaver::WeaverReadResponse;
using aidl::android::hardware::weaver::WeaverReadStatus;

struct RecoveryWeaver : public BnWeaver {
    ::ndk::ScopedAStatus getConfig(WeaverConfig *out_config) override {
        uint8_t resp_buf[64] = {};
        uint32_t reply_len = sizeof(resp_buf);
        uint32_t call_status = 0;

        int ret = nos_call(APP_ID_WEAVER, WEAVER_GET_CONFIG,
                            nullptr, 0,
                            resp_buf, &reply_len, &call_status);

        if (ret < 0 || call_status != APP_SUCCESS || reply_len < 16) {
            LOG(ERROR) << "getConfig failed: ret=" << ret
                       << " status=0x" << std::hex << call_status
                       << " len=" << std::dec << reply_len;
            return ndk::ScopedAStatus::fromServiceSpecificError(1);
        }

        out_config->slots     = static_cast<int32_t>(rd32(resp_buf + 4));
        out_config->keySize   = static_cast<int32_t>(rd32(resp_buf + 8));
        out_config->valueSize = static_cast<int32_t>(rd32(resp_buf + 12));

        LOG(INFO) << "getConfig: slots=" << out_config->slots
                  << " keySize=" << out_config->keySize
                  << " valueSize=" << out_config->valueSize;
        return ndk::ScopedAStatus::ok();
    }

    ::ndk::ScopedAStatus read(int32_t in_slotId,
                              const std::vector<uint8_t> &in_key,
                              WeaverReadResponse *out_response) override {
        if (in_key.size() != 16) {
            LOG(ERROR) << "read: bad key size " << in_key.size();
            *out_response = {0, {}, WeaverReadStatus::FAILED};
            return ndk::ScopedAStatus::ok();
        }

        uint8_t req_buf[24] = {};
        wr32(req_buf + 0, WEAVER_MSG_HDR);
        wr32(req_buf + 4, static_cast<uint32_t>(in_slotId));
        memcpy(req_buf + 8, in_key.data(), 16);

        uint8_t resp_buf[64] = {};
        uint32_t reply_len = sizeof(resp_buf);
        uint32_t call_status = 0;

        int ret = nos_call(APP_ID_WEAVER, WEAVER_READ,
                            req_buf, sizeof(req_buf),
                            resp_buf, &reply_len, &call_status);

        if (ret < 0 || call_status != APP_SUCCESS || reply_len < 32) {
            LOG(ERROR) << "read slot " << in_slotId << " failed: ret=" << ret
                       << " status=0x" << std::hex << call_status
                       << " len=" << std::dec << reply_len;
            *out_response = {0, {}, WeaverReadStatus::FAILED};
            return ndk::ScopedAStatus::ok();
        }

        uint32_t error = rd32(resp_buf + 4);
        uint32_t throttle = rd32(resp_buf + 8);

        std::vector<uint8_t> value;
        WeaverReadStatus status;
        if (error == 0) {
            status = WeaverReadStatus::OK;
            value.assign(resp_buf + 16, resp_buf + 32);
        } else {
            // Non-zero means the key did not match (or the slot is throttled);
            // report INCORRECT_KEY so the caller re-prompts.
            status = WeaverReadStatus::INCORRECT_KEY;
        }

        out_response->timeout = static_cast<int64_t>(throttle);
        out_response->value = std::move(value);
        out_response->status = status;

        LOG(INFO) << "read slot " << in_slotId << ": error=" << error
                  << " throttle=" << throttle
                  << " value_len=" << out_response->value.size();
        return ndk::ScopedAStatus::ok();
    }

    ::ndk::ScopedAStatus write(int32_t in_slotId,
                               const std::vector<uint8_t> &in_key,
                               const std::vector<uint8_t> &in_value) override {
        // Recovery never enrolls credentials, so this path is not exercised;
        // it mirrors read's raw layout for completeness.
        if (in_key.size() != 16 || in_value.size() != 16) {
            LOG(ERROR) << "write: bad key/value size";
            return ndk::ScopedAStatus::fromServiceSpecificError(1);
        }

        uint8_t req_buf[64] = {};
        wr32(req_buf + 0, WEAVER_MSG_HDR);
        wr32(req_buf + 4, static_cast<uint32_t>(in_slotId));
        memcpy(req_buf + 8, in_key.data(), 16);
        memcpy(req_buf + 24, in_value.data(), 16);

        uint32_t call_status = 0;
        int ret = nos_call(APP_ID_WEAVER, WEAVER_WRITE,
                            req_buf, 40,
                            nullptr, nullptr, &call_status);

        if (ret < 0 || call_status != APP_SUCCESS) {
            LOG(ERROR) << "write slot " << in_slotId
                        << " failed: ret=" << ret
                        << " status=0x" << std::hex << call_status;
            return ndk::ScopedAStatus::fromServiceSpecificError(1);
        }

        LOG(INFO) << "write slot " << in_slotId << ": ok";
        return ndk::ScopedAStatus::ok();
    }
};

int main() {
    LOG(INFO) << "recovery_weaver starting";

    if (gsc_open("/dev/gsc0") < 0) {
        LOG(FATAL) << "Cannot open /dev/gsc0";
        return 1;
    }

    ABinderProcess_setThreadPoolMaxThreadCount(0);

    auto weaver = ndk::SharedRefBase::make<RecoveryWeaver>();
    const std::string instance =
        std::string(RecoveryWeaver::descriptor) + "/default";

    binder_status_t status =
        AServiceManager_addService(weaver->asBinder().get(), instance.c_str());
    if (status != STATUS_OK) {
        LOG(FATAL) << "Failed to register " << instance << ": " << status;
        return 1;
    }

    LOG(INFO) << "Registered " << instance;
    ABinderProcess_joinThreadPool();
    return 0;
}
