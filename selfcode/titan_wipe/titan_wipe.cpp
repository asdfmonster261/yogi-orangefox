/*
 * titan_wipe - erase the user secrets on the Titan M3, as the stock recovery's
 * factory reset does
 *
 *   titan_wipe --check   read the firmware version, to test the connection
 *   titan_wipe --erase   erase every user secret the chip holds; there is no undo
 *
 * The erase leaves the current /data permanently undecryptable, so it only belongs
 * at the end of Format Data, after the userdata discard. /dev/gsc0 opens once at a
 * time, so recovery_weaver has to be stopped first.
 */

#include <android-base/logging.h>
#include <app_nugget.h>
#include <application.h>
#include <nos/NuggetClient.h>
#include <nos/debug.h>

#include <endian.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

// Stock gives up after five tries.
constexpr int kEraseAttempts = 5;

int Check() {
    nos::NuggetClient client;
    client.Open();
    if (!client.IsOpen()) {
        LOG(ERROR) << "Failed to connect to Titan M";
        return 1;
    }

    // CallApp fills the reply up to its capacity.
    std::vector<uint8_t> reply;
    reply.reserve(512);
    const uint32_t status =
            client.CallApp(APP_ID_NUGGET, NUGGET_PARAM_VERSION, std::vector<uint8_t>(), &reply);
    if (status != APP_SUCCESS) {
        LOG(ERROR) << "Titan M version read failed: " << nos::StatusCodeString(status) << " ("
                   << status << ")";
        return 1;
    }

    const std::string version(reply.begin(), reply.end());
    LOG(INFO) << "Titan M firmware: " << version.c_str();
    return 0;
}

int Erase() {
    const uint32_t confirmation = htole32(ERASE_CONFIRMATION);
    std::vector<uint8_t> magic(sizeof(confirmation));
    memcpy(magic.data(), &confirmation, sizeof(confirmation));

    for (int attempt = 1; attempt <= kEraseAttempts; ++attempt) {
        nos::NuggetClient client;
        client.Open();
        if (!client.IsOpen()) {
            LOG(ERROR) << "Failed to connect to Titan M";
            continue;
        }

        const uint32_t status =
                client.CallApp(APP_ID_NUGGET, NUGGET_PARAM_NUKE_FROM_ORBIT, magic, nullptr);
        if (status == APP_SUCCESS) {
            LOG(INFO) << "Titan M wipe successful";
            return 0;
        }
        LOG(ERROR) << "Titan M user data wipe failed: " << nos::StatusCodeString(status) << " ("
                   << status << ")";
    }
    return 1;
}

}  // namespace

int main(int argc, char** argv) {
    android::base::InitLogging(argv, android::base::StderrLogger);

    if (argc == 2 && strcmp(argv[1], "--check") == 0) return Check();
    if (argc == 2 && strcmp(argv[1], "--erase") == 0) return Erase();

    LOG(ERROR) << "usage: titan_wipe --check | --erase";
    return 2;
}
