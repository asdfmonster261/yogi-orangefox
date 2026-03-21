/*
 * recovery_weaver - A14-native Weaver HAL proxy for Pixel 8 recovery
 *
 * Talks to Titan M2 (GSC) directly via /dev/gsc0 one_pass_call ioctl.
 * GSC Weaver uses protobuf serialization (APP_ID_WEAVER 0x03).
 * Registers IWeaver/default on binder for CE FBE decryption.
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


static bool pb_decode_varint(const uint8_t *buf, uint32_t len,
                             uint32_t *pos, uint64_t *val) {
    *val = 0;
    unsigned shift = 0;
    while (*pos < len) {
        uint8_t b = buf[(*pos)++];
        *val |= (uint64_t)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) return true;
        shift += 7;
        if (shift >= 64) return false;
    }
    return false;
}

static void pb_encode_varint(uint8_t *buf, uint32_t *pos, uint64_t val) {
    while (val > 0x7F) {
        buf[(*pos)++] = (uint8_t)(val & 0x7F) | 0x80;
        val >>= 7;
    }
    buf[(*pos)++] = (uint8_t)val;
}

static void pb_encode_uint32(uint8_t *buf, uint32_t *pos,
                                uint32_t field, uint32_t val) {
    pb_encode_varint(buf, pos, (uint64_t)(field << 3) | 0);
    pb_encode_varint(buf, pos, val);
}

static void pb_encode_bytes(uint8_t *buf, uint32_t *pos,
                             uint32_t field, const uint8_t *data, uint32_t len) {
    pb_encode_varint(buf, pos, (uint64_t)(field << 3) | 2);
    pb_encode_varint(buf, pos, len);
    memcpy(buf + *pos, data, len);
    *pos += len;
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

        if (ret < 0 || call_status != APP_SUCCESS) {
            LOG(ERROR) << "getConfig failed: ret=" << ret
                        << " status=0x" << std::hex << call_status;
            return ndk::ScopedAStatus::fromServiceSpecificError(1);
        }

        uint32_t slots = 0, key_size = 0, value_size = 0;
        uint32_t pos = 0;
        while (pos < reply_len) {
            uint64_t tag;
            if (!pb_decode_varint(resp_buf, reply_len, &pos, &tag)) break;
            uint32_t field = tag >> 3;
            uint32_t wire = tag & 0x7;
            if (wire == 0) {
                uint64_t val;
                if (!pb_decode_varint(resp_buf, reply_len, &pos, &val)) break;
                switch (field) {
                    case 1: slots = (uint32_t)val; break;
                    case 2: key_size = (uint32_t)val; break;
                    case 3: value_size = (uint32_t)val; break;
                }
            } else if (wire == 2) {
                uint64_t slen;
                if (!pb_decode_varint(resp_buf, reply_len, &pos, &slen)) break;
                pos += (uint32_t)slen;
            } else {
                break;
            }
        }

        out_config->slots    = static_cast<int32_t>(slots);
        out_config->keySize  = static_cast<int32_t>(key_size);
        out_config->valueSize = static_cast<int32_t>(value_size);

        LOG(INFO) << "getConfig: slots=" << slots
                    << " keySize=" << key_size
                    << " valueSize=" << value_size;
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

        uint8_t req_buf[64] = {};
        uint32_t req_len = 0;
        pb_encode_uint32(req_buf, &req_len, 1, static_cast<uint32_t>(in_slotId));
        pb_encode_bytes(req_buf, &req_len, 2, in_key.data(), 16);

        uint8_t resp_buf[128] = {};
        uint32_t reply_len = sizeof(resp_buf);
        uint32_t call_status = 0;

        int ret = nos_call(APP_ID_WEAVER, WEAVER_READ,
                            req_buf, req_len,
                            resp_buf, &reply_len, &call_status);

        if (ret < 0 || call_status != APP_SUCCESS) {
            LOG(ERROR) << "read slot " << in_slotId
                        << " failed: ret=" << ret
                        << " status=0x" << std::hex << call_status;
            *out_response = {0, {}, WeaverReadStatus::FAILED};
            return ndk::ScopedAStatus::ok();
        }

        uint32_t error = 0, throttle_msec = 0;
        std::vector<uint8_t> value;
        uint32_t pos = 0;
        while (pos < reply_len) {
            uint64_t tag;
            if (!pb_decode_varint(resp_buf, reply_len, &pos, &tag)) break;
            uint32_t field = tag >> 3;
            uint32_t wire = tag & 0x7;
            if (wire == 0) {
                uint64_t val;
                if (!pb_decode_varint(resp_buf, reply_len, &pos, &val)) break;
                switch (field) {
                    case 1: error = (uint32_t)val; break;
                    case 2: throttle_msec = (uint32_t)val; break;
                }
            } else if (wire == 2) {
                uint64_t slen;
                if (!pb_decode_varint(resp_buf, reply_len, &pos, &slen)) break;
                if (field == 3 && pos + slen <= reply_len) {
                    value.assign(resp_buf + pos, resp_buf + pos + slen);
                }
                pos += (uint32_t)slen;
            } else {
                break;
            }
        }

        WeaverReadStatus aidl_status;
        switch (error) {
            case 0: aidl_status = WeaverReadStatus::OK; break;
            case 1: aidl_status = WeaverReadStatus::INCORRECT_KEY; break;
            case 2: aidl_status = WeaverReadStatus::THROTTLE; break;
            default: aidl_status = WeaverReadStatus::FAILED; break;
        }

        out_response->timeout = static_cast<long>(throttle_msec);
        out_response->value = std::move(value);
        out_response->status = aidl_status;

        LOG(INFO) << "read slot " << in_slotId
                    << ": error=" << error
                    << " throttle=" << throttle_msec
                    << " value_len=" << out_response->value.size();
        return ndk::ScopedAStatus::ok();
    }

    ::ndk::ScopedAStatus write(int32_t in_slotId,
                                const std::vector<uint8_t> &in_key,
                                const std::vector<uint8_t> &in_value) override {
        if (in_key.size() != 16 || in_value.size() != 16) {
            LOG(ERROR) << "write: bad key/value size";
            return ndk::ScopedAStatus::fromServiceSpecificError(1);
        }

        uint8_t req_buf[64] = {};
        uint32_t req_len = 0;
        pb_encode_uint32(req_buf, &req_len, 1, static_cast<uint32_t>(in_slotId));
        pb_encode_bytes(req_buf, &req_len, 2, in_key.data(), 16);
        pb_encode_bytes(req_buf, &req_len, 3, in_value.data(), 16);

        uint32_t call_status = 0;
        int ret = nos_call(APP_ID_WEAVER, WEAVER_WRITE,
                            req_buf, req_len,
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
