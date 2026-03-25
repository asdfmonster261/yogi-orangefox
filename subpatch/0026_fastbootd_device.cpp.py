from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Fix fastbootd: non-blocking HAL lookups (health + fastboot, AIDL + HIDL)"
        self.target_file = "system/core/fastboot/device/fastboot_device.cpp"

        # Root cause: The FastbootDevice constructor initializes three HAL handles
        # synchronously. In recovery two of them block if the HAL is not running:
        #
        # 1. health_hal_ → get_health_service():
        #    Block A (AIDL): AServiceManager_waitForService() blocks indefinitely when
        #      android.hardware.health.IHealth/default is declared in VINTF but the
        #      service binary cannot start in recovery (init returns error 0x20).
        #    Block B (HIDL): android::hardware::health::V2_0::get_health_service() calls
        #      IHealth::getService() which retries with a 1-second-per-attempt loop via
        #      HidlServiceManagement. Even with Block A fixed, Block B consumes ~1 second.
        #
        # 2. fastboot_hal_ → get_fastboot_service():
        #    Block C (AIDL): same AServiceManager_waitForService() pattern (if declared).
        #    Block D (HIDL): HidlFastboot::getService() retries for ~1 second as well.
        #
        # Total blocking without fixes: up to 3+ seconds; TWRP kills fastbootd at ~1.4s.
        # As a result, sys.usb.ffs.ready=1 is never set, USB gadget never switches to
        # fastbootd mode, and the device remains in ADB recovery mode.
        #
        # Fixes:
        #   AIDL paths: waitForService → checkService  (returns nullptr immediately)
        #   HIDL paths: getService    → tryGetService  (returns nullptr immediately)
        #
        # Health and fastboot HAL implementations are non-essential for protocol
        # operation — fastbootd works correctly without them in recovery.

        self.CHANGES = [
            (
                # Fix 1 (health): AIDL — checkService (non-blocking) + HIDL — tryGetService (non-blocking)
                r"""    if (AServiceManager_isDeclared(service_name.c_str())) {
        ndk::SpAIBinder binder(AServiceManager_waitForService(service_name.c_str()));
        std::shared_ptr<IHealth> health = IHealth::fromBinder(binder);
        if (health != nullptr) return health;
        LOG(WARNING) << "AIDL health service is declared, but it cannot be retrieved.";
    }
    LOG(INFO) << "Unable to get AIDL health service, trying HIDL...";
    android::sp<HidlHealth> hidl_health = android::hardware::health::V2_0::get_health_service();
    if (hidl_health != nullptr) {
        return ndk::SharedRefBase::make<HealthShim>(hidl_health);
    }
    LOG(WARNING) << "No health implementation is found.";
    return nullptr;""",

                # Fixed: both AIDL and HIDL use non-blocking service lookup
                r"""    if (AServiceManager_isDeclared(service_name.c_str())) {
        // Non-blocking: checkService returns nullptr immediately if not available.
        // In recovery, health HAL is declared in VINTF but cannot be started by init,
        // so waitForService would block indefinitely.
        ndk::SpAIBinder binder(AServiceManager_checkService(service_name.c_str()));
        std::shared_ptr<IHealth> health = IHealth::fromBinder(binder);
        if (health != nullptr) return health;
        LOG(WARNING) << "AIDL health service is declared, but it cannot be retrieved.";
    }
    LOG(INFO) << "Unable to get AIDL health service, trying HIDL...";
    // Non-blocking: tryGetService returns nullptr immediately if not registered.
    // get_health_service() uses IHealth::getService() which retries for ~1s per attempt.
    android::sp<HidlHealth> hidl_health = HidlHealth::tryGetService("default");
    if (hidl_health != nullptr) {
        return ndk::SharedRefBase::make<HealthShim>(hidl_health);
    }
    LOG(WARNING) << "No health implementation is found.";
    return nullptr;""",
            ),
            (
                # Fix 2 (fastboot HAL): AIDL — checkService + HIDL — tryGetService (both non-blocking)
                # AServiceManager_waitForService blocks if service is declared but unavailable.
                # HidlFastboot::getService() retries for ~1s if not registered in hwservicemanager.
                r"""    if (AServiceManager_isDeclared(service_name.c_str())) {
        ndk::SpAIBinder binder(AServiceManager_waitForService(service_name.c_str()));
        std::shared_ptr<IFastboot> fastboot = IFastboot::fromBinder(binder);
        if (fastboot != nullptr) {
            LOG(INFO) << "Found and using AIDL fastboot service";
            return fastboot;
        }
        LOG(WARNING) << "AIDL fastboot service is declared, but it cannot be retrieved.";
    }
    LOG(INFO) << "Unable to get AIDL fastboot service, trying HIDL...";
    android::sp<HidlFastboot> hidl_fastboot = HidlFastboot::getService();
    if (hidl_fastboot != nullptr) {
        LOG(INFO) << "Found and now using fastboot HIDL implementation";
        return ndk::SharedRefBase::make<FastbootShim>(hidl_fastboot);
    }
    LOG(WARNING) << "No fastboot implementation is found.";
    return nullptr;""",

                # Fixed: non-blocking lookups for both AIDL and HIDL fastboot HAL
                r"""    if (AServiceManager_isDeclared(service_name.c_str())) {
        // Non-blocking: checkService returns nullptr immediately if service is unavailable.
        ndk::SpAIBinder binder(AServiceManager_checkService(service_name.c_str()));
        std::shared_ptr<IFastboot> fastboot = IFastboot::fromBinder(binder);
        if (fastboot != nullptr) {
            LOG(INFO) << "Found and using AIDL fastboot service";
            return fastboot;
        }
        LOG(WARNING) << "AIDL fastboot service is declared, but it cannot be retrieved.";
    }
    LOG(INFO) << "Unable to get AIDL fastboot service, trying HIDL...";
    // Non-blocking: tryGetService returns nullptr immediately if not in hwservicemanager.
    // getService() would retry for ~1s per attempt and delay fastbootd startup.
    android::sp<HidlFastboot> hidl_fastboot = HidlFastboot::tryGetService();
    if (hidl_fastboot != nullptr) {
        LOG(INFO) << "Found and now using fastboot HIDL implementation";
        return ndk::SharedRefBase::make<FastbootShim>(hidl_fastboot);
    }
    LOG(WARNING) << "No fastboot implementation is found.";
    return nullptr;""",
            ),
        ]
