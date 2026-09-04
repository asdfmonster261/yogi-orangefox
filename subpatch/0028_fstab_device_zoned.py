from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "fs_mgr: support inline device=zoned:/device=exp: userdata syntax"
        self.target_file = "system/core/fs_mgr/libfstab/fstab.cpp"

        # Newer Pixels (Android 15+) name the userdata sub-devices inline:
        # device=zoned:<path> (the zoned LU) and device=exp:/device=exp_alias:<path>
        # (expansion devices). The bare zoned_device flag path leaves these unparsed,
        # so vold never sets up their dm-default-key devices and the F2FS multi-device
        # mount fails. Additive: inert for devices that don't use the inline forms.
        self.CHANGES = [
            (
                r"""        } else if (flag == "zoned_device") {
            if (access("/dev/block/by-name/zoned_device", F_OK) == 0) {
                entry->zoned_device = "/dev/block/by-name/zoned_device";

                // atgc in f2fs does not support a zoned device
                auto options = Split(entry->fs_options, ",");
                options.erase(std::remove(options.begin(), options.end(), "atgc"), options.end());
                entry->fs_options = android::base::Join(options, ",");
                LINFO << "Removed ATGC in fs_options as " << entry->fs_options
                      << " for zoned device=" << entry->zoned_device;
            }
        } else {""",
                r"""        } else if (flag == "zoned_device") {
            if (access("/dev/block/by-name/zoned_device", F_OK) == 0) {
                entry->zoned_device = "/dev/block/by-name/zoned_device";

                // atgc in f2fs does not support a zoned device
                auto options = Split(entry->fs_options, ",");
                options.erase(std::remove(options.begin(), options.end(), "atgc"), options.end());
                entry->fs_options = android::base::Join(options, ",");
                LINFO << "Removed ATGC in fs_options as " << entry->fs_options
                      << " for zoned device=" << entry->zoned_device;
            }
        } else if (StartsWith(flag, "device=zoned:")) {
            // Inline zoned-device syntax (Android 15+): device=zoned:<path>, the
            // newer form of the zoned_device flag above.
            const auto zoned_dev = arg.substr(arg.find(':') + 1);
            if (access(zoned_dev.c_str(), F_OK) == 0) {
                entry->zoned_device = zoned_dev;

                // atgc in f2fs does not support a zoned device
                auto options = Split(entry->fs_options, ",");
                options.erase(std::remove(options.begin(), options.end(), "atgc"), options.end());
                entry->fs_options = android::base::Join(options, ",");
                LINFO << "Removed ATGC in fs_options as " << entry->fs_options
                      << " for zoned device=" << entry->zoned_device;
            }
        } else if (StartsWith(flag, "device=exp:") || StartsWith(flag, "device=exp_alias:")) {
            // F2FS expansion devices; each needs its own dm-default-key at decrypt.
            const auto exp_dev = arg.substr(arg.find(':') + 1);
            if (access(exp_dev.c_str(), F_OK) == 0) {
                entry->user_devices.push_back(exp_dev);
            }
        } else {""",
            ),
        ]
