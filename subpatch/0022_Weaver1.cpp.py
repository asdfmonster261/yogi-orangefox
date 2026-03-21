from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom DE modifications (Weaver1.cpp)"
        self.target_file = "system/vold/Weaver1.cpp" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
#include <iostream>
#define ERROR 1
#define LOG(x) std::cout

using namespace android::hardware::weaver;
using android::hardware::hidl_string;
using ::android::hardware::weaver::V1_0::IWeaver;
using ::android::hardware::weaver::V1_0::WeaverConfig;
using ::android::hardware::weaver::V1_0::WeaverReadStatus;
using ::android::hardware::weaver::V1_0::WeaverReadResponse;
using ::android::hardware::weaver::V1_0::WeaverStatus;
using ::android::hardware::Return;
using ::android::sp;

namespace android {
namespace vold {

Weaver::Weaver() {
    const std::string instance = std::string(::aidl::android::hardware::weaver::IWeaver::descriptor) + "/default";
    AIBinder* binder = AServiceManager_waitForService(instance.c_str());
    mAidlDevice = ::aidl::android::hardware::weaver::IWeaver::fromBinder(ndk::SpAIBinder(binder));
	if (mAidlDevice == nullptr) {
		mDevice = ::android::hardware::weaver::V1_0::IWeaver::getService();
	}
	GottenConfig = false;
}
""",
                # Блок 1: Модифицированный код (результат)
                r"""
#include <iostream>
#include <unistd.h>
#define ERROR 1
#define LOG(x) std::cout

using namespace android::hardware::weaver;
using android::hardware::hidl_string;
using ::android::hardware::weaver::V1_0::IWeaver;
using ::android::hardware::weaver::V1_0::WeaverConfig;
using ::android::hardware::weaver::V1_0::WeaverReadStatus;
using ::android::hardware::weaver::V1_0::WeaverReadResponse;
using ::android::hardware::weaver::V1_0::WeaverStatus;
using ::android::hardware::Return;
using ::android::sp;

namespace android {
namespace vold {

Weaver::Weaver() {
    const std::string instance = std::string(::aidl::android::hardware::weaver::IWeaver::descriptor) + "/default";
    // Use checkService with bounded retry instead of waitForService to avoid
    // infinite hang when Weaver HAL is not registered, while still allowing
    // time for the service to start during early boot.
    AIBinder* binder = nullptr;
    for (int i = 0; i < 15; i++) {
        binder = AServiceManager_checkService(instance.c_str());
        if (binder) break;
        LOG(ERROR) << "Weaver service not yet available, retrying (" << (i + 1) << "/15)..." << std::endl;
        sleep(2);
    }
    if (binder) {
        mAidlDevice = ::aidl::android::hardware::weaver::IWeaver::fromBinder(ndk::SpAIBinder(binder));
    }
	if (mAidlDevice == nullptr) {
		mDevice = ::android::hardware::weaver::V1_0::IWeaver::getService();
	}
	GottenConfig = false;
}
"""
            )
        ]

