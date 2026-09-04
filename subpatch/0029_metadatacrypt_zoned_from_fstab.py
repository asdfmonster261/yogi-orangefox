from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "vold: multi-device metadata decrypt (zoned + expansion devices)"
        self.target_file = "system/vold/MetadataCrypt.cpp"

        # TWRP passes an empty zoned_device, so recover it (and the expansion devices)
        # from the fstab entry that libfstab now parses. The per-device key subdir and
        # the dm-default-key device name are both the device basename, because F2FS
        # finds multi-device members by their /dev/block/mapper/<basename> superblock
        # paths.
        self.CHANGES = [
            (
                r"""    auto default_metadata_key_dir = data_rec->metadata_key_dir;
    if (!zoned_device.empty()) {
        default_metadata_key_dir = default_metadata_key_dir + "/default";
    }""",
                r"""    const std::string& zoned_dev = zoned_device.empty() ? data_rec->zoned_device : zoned_device;
    auto default_metadata_key_dir = data_rec->metadata_key_dir;
    if (!zoned_dev.empty()) {
        default_metadata_key_dir = default_metadata_key_dir + "/default";
    }""",
            ),
            (
                r"""    // create dm-default-key for zoned device
    std::string crypto_zoned_blkdev;
    if (!zoned_device.empty()) {
        auto zoned_metadata_key_dir = data_rec->metadata_key_dir + "/zoned";

        if (!read_key(zoned_metadata_key_dir, gen, false, &key)) {
            LOG(ERROR) << "read_key failed with zoned device: " << zoned_device;
            return false;
        }
        if (!create_crypto_blk_dev(kDmNameUserdataZoned, zoned_device, key, options,
                                   &crypto_zoned_blkdev, &nr_sec)) {
            LOG(ERROR) << "fscrypt_mount_metadata_encrypted: failed with zoned device: "
                       << zoned_device;
            return false;
        }
    }""",
                r"""    // create dm-default-key for zoned device
    std::string crypto_zoned_blkdev;
    if (!zoned_dev.empty()) {
        auto zoned_metadata_key_dir =
            data_rec->metadata_key_dir + "/" + zoned_dev.substr(zoned_dev.rfind('/') + 1);

        if (!read_key(zoned_metadata_key_dir, gen, false, &key)) {
            LOG(ERROR) << "read_key failed with zoned device: " << zoned_dev;
            return false;
        }
        if (!create_crypto_blk_dev(kDmNameUserdataZoned, zoned_dev, key, options,
                                   &crypto_zoned_blkdev, &nr_sec)) {
            LOG(ERROR) << "fscrypt_mount_metadata_encrypted: failed with zoned device: "
                       << zoned_dev;
            return false;
        }
    }

    // create dm-default-key for each F2FS expansion device (device=exp:/device=exp_alias:).
    // The dm device name must be the basename so it appears at /dev/block/mapper/<basename>,
    // which is the path F2FS reads from the superblock.
    for (const auto& exp_dev : data_rec->user_devices) {
        const auto exp_name = exp_dev.substr(exp_dev.rfind('/') + 1);
        KeyBuffer exp_key;
        if (!read_key(data_rec->metadata_key_dir + "/" + exp_name, gen, false, &exp_key)) {
            LOG(ERROR) << "read_key failed for expansion device: " << exp_dev;
            return false;
        }
        std::string exp_blkdev;
        uint64_t exp_nr_sec;
        if (!create_crypto_blk_dev(exp_name, exp_dev, exp_key, options, &exp_blkdev,
                                   &exp_nr_sec)) {
            LOG(ERROR) << "create_crypto_blk_dev failed for expansion device: " << exp_dev;
            return false;
        }
    }""",
            ),
            (
                r"""static const std::string kDmNameUserdataZoned = "userdata_zoned";""",
                r"""static const std::string kDmNameUserdataZoned = "zoned_device";""",
            ),
        ]
